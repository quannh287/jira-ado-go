package syncjob

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"maps"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

// Store holds jobs and runs (newest first) in memory for the UI; when opened on a database, every change is written through to it.
// ponytail: loads every run at startup, page runs from SQL when history gets large
type Store struct {
	Jobs []Job
	Runs []Run
	// Settings are app-wide key/values (ADO org, Jira URL…); secrets go to the keychain, never here.
	Settings map[string]string
	// OnSaveError reports a failed write; the change stays in memory.
	OnSaveError func(error)

	db      *sqlite.DB
	mem     *memState // State when there is no database
	nextJob int
	nextRun int
	now     func() time.Time
}

const dbTimeout = 5 * time.Second

// migrations[i] moves the schema from user_version i to i+1; append, never edit a shipped step.
var migrations = [][]string{{
	`CREATE TABLE IF NOT EXISTS jobs (
		id INTEGER PRIMARY KEY, name TEXT NOT NULL, jira_key TEXT NOT NULL, ado_project TEXT NOT NULL,
		type TEXT NOT NULL, status TEXT NOT NULL, created INTEGER NOT NULL,
		mappings TEXT NOT NULL, filters TEXT NOT NULL)`,
	`CREATE TABLE IF NOT EXISTS job_activity (
		id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
		at INTEGER NOT NULL, text TEXT NOT NULL)`,
	`CREATE TABLE IF NOT EXISTS runs (
		id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
		started INTEGER NOT NULL, duration_ms INTEGER NOT NULL)`,
	`CREATE TABLE IF NOT EXISTS tickets (
		id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
		key TEXT NOT NULL, summary TEXT NOT NULL, outcome TEXT NOT NULL, error TEXT NOT NULL,
		calls TEXT NOT NULL)`,
	`CREATE INDEX IF NOT EXISTS runs_job ON runs(job_id)`,
	`CREATE INDEX IF NOT EXISTS tickets_run ON tickets(run_id)`,
}, {
	`ALTER TABLE runs ADD COLUMN since TEXT NOT NULL DEFAULT ''`,
	`ALTER TABLE runs ADD COLUMN error TEXT NOT NULL DEFAULT ''`,
	`ALTER TABLE tickets ADD COLUMN work_item_type TEXT NOT NULL DEFAULT ''`,
	`ALTER TABLE tickets ADD COLUMN ado_id INTEGER NOT NULL DEFAULT 0`,
	`ALTER TABLE tickets ADD COLUMN message TEXT NOT NULL DEFAULT ''`,
	`CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
	// Cursor per job: the sync only asks Jira for issues updated since it.
	`CREATE TABLE sync_state (job_id INTEGER PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE, cursor TEXT NOT NULL)`,
	`CREATE TABLE comment_mappings (
		ado_work_item_id INTEGER NOT NULL, jira_comment_id TEXT NOT NULL,
		ado_comment_id INTEGER NOT NULL, jira_updated TEXT NOT NULL,
		PRIMARY KEY (ado_work_item_id, jira_comment_id))`,
}}

// NewStore is an in-memory store, for tests and demos.
func NewStore(now func() time.Time) *Store {
	return &Store{now: now, Settings: map[string]string{}, mem: newMemState()}
}

// Open loads the SQLite database at path, creating it when missing. Close the store when done.
func Open(path string, now func() time.Time) (*Store, error) {
	ctx, cancel := context.WithTimeout(context.Background(), dbTimeout)
	defer cancel()
	db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{})
	if err != nil {
		return nil, err
	}
	s := &Store{db: db, now: now, Settings: map[string]string{}}
	if err := s.load(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	if s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *Store) migrate(ctx context.Context) error {
	rows, err := s.db.Query(ctx, `PRAGMA user_version`)
	if err != nil {
		return err
	}
	version := toInt(rows.Values[0][0])
	for v := version; v < len(migrations); v++ {
		stmts := make([]sqlite.Statement, 0, len(migrations[v])+1)
		for _, q := range migrations[v] {
			stmts = append(stmts, stmt(q))
		}
		stmts = append(stmts, stmt(fmt.Sprintf(`PRAGMA user_version = %d`, v+1)))
		if _, err := s.db.Transaction(ctx, stmts); err != nil {
			return fmt.Errorf("migrate schema to v%d: %w", v+1, err)
		}
	}
	return nil
}

func (s *Store) load(ctx context.Context) error {
	if err := s.migrate(ctx); err != nil {
		return err
	}
	settings, err := s.db.Query(ctx, `SELECT key, value FROM settings`)
	if err != nil {
		return err
	}
	for _, r := range settings.Values {
		s.Settings[r[0].(string)] = r[1].(string)
	}
	jobs, err := s.db.Query(ctx, `SELECT id, name, jira_key, ado_project, type, status, created, mappings, filters FROM jobs ORDER BY id`)
	if err != nil {
		return err
	}
	byID := map[int]*Job{}
	s.Jobs = make([]Job, 0, len(jobs.Values))
	for _, r := range jobs.Values {
		j := Job{ID: toInt(r[0]), Name: r[1].(string), JiraKey: r[2].(string), ADOProject: r[3].(string),
			Type: SyncType(r[4].(string)), Status: Status(r[5].(string)), Created: fromMillis(r[6])}
		if err := unmarshal(r[7], &j.Mappings); err != nil {
			return err
		}
		if err := unmarshal(r[8], &j.Filters); err != nil {
			return err
		}
		s.Jobs = append(s.Jobs, j)
		s.nextJob = max(s.nextJob, j.ID)
	}
	for i := range s.Jobs {
		byID[s.Jobs[i].ID] = &s.Jobs[i]
	}

	acts, err := s.db.Query(ctx, `SELECT job_id, at, text FROM job_activity ORDER BY id`)
	if err != nil {
		return err
	}
	for _, r := range acts.Values {
		if j := byID[toInt(r[0])]; j != nil {
			j.Activity = append(j.Activity, Activity{At: fromMillis(r[1]), Text: r[2].(string)})
		}
	}

	runs, err := s.db.Query(ctx, `SELECT id, job_id, started, duration_ms, since, error FROM runs ORDER BY id DESC`)
	if err != nil {
		return err
	}
	runIdx := map[int]int{}
	for _, r := range runs.Values {
		run := Run{ID: toInt(r[0]), JobID: toInt(r[1]), Started: fromMillis(r[2]), Duration: time.Duration(toInt(r[3])) * time.Millisecond,
			Since: r[4].(string), Error: r[5].(string)}
		runIdx[run.ID] = len(s.Runs)
		s.Runs = append(s.Runs, run)
		s.nextRun = max(s.nextRun, run.ID)
	}

	tickets, err := s.db.Query(ctx, `SELECT run_id, key, summary, outcome, error, calls, work_item_type, ado_id, message FROM tickets ORDER BY id`)
	if err != nil {
		return err
	}
	for _, r := range tickets.Values {
		i, ok := runIdx[toInt(r[0])]
		if !ok {
			continue
		}
		t := Ticket{Key: r[1].(string), Summary: r[2].(string), Outcome: Outcome(r[3].(string)), Error: r[4].(string),
			WorkItemType: r[6].(string), ADOID: toInt(r[7]), Message: r[8].(string)}
		if err := unmarshal(r[5], &t.Calls); err != nil {
			return err
		}
		s.Runs[i].Tickets = append(s.Runs[i].Tickets, t)
	}
	return nil
}

// write runs statements atomically; memory is already updated, so a failure is only reported.
func (s *Store) write(stmts ...sqlite.Statement) {
	if s.db == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), dbTimeout)
	defer cancel()
	if _, err := s.db.Transaction(ctx, stmts); err != nil {
		slog.Error("store write failed", "statements", len(stmts), "first", firstWords(stmts), "err", err)
		if s.OnSaveError != nil {
			s.OnSaveError(err)
		}
	}
}

func stmt(sql string, args ...any) sqlite.Statement { return sqlite.Statement{SQL: sql, Args: args} }

func (s *Store) AddJob(j Job) int {
	s.nextJob++
	j.ID = s.nextJob
	j.Status = Active
	j.Created = s.now()
	j.Activity = []Activity{{At: j.Created, Text: "Job created"}}
	s.Jobs = append(s.Jobs, j)
	s.write(
		stmt(`INSERT INTO jobs (id, name, jira_key, ado_project, type, status, created, mappings, filters) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			j.ID, j.Name, j.JiraKey, j.ADOProject, string(j.Type), string(j.Status), j.Created.UnixMilli(), marshal(j.Mappings), marshal(j.Filters)),
		stmt(`INSERT INTO job_activity (job_id, at, text) VALUES (?, ?, ?)`, j.ID, j.Created.UnixMilli(), j.Activity[0].Text),
	)
	return j.ID
}

func (s *Store) Job(id int) *Job {
	for i := range s.Jobs {
		if s.Jobs[i].ID == id {
			return &s.Jobs[i]
		}
	}
	return nil
}

// UpdateJob saves a job's editable settings; ID, status, creation and activity stay the store's.
func (s *Store) UpdateJob(j Job) {
	cur := s.Job(j.ID)
	if cur == nil {
		return
	}
	cur.Name, cur.ADOProject, cur.Type, cur.Mappings, cur.Filters = j.Name, j.ADOProject, j.Type, j.Mappings, j.Filters
	a := Activity{At: s.now(), Text: "Job settings changed"}
	cur.Activity = append(cur.Activity, a)
	s.write(
		stmt(`UPDATE jobs SET name = ?, ado_project = ?, type = ?, mappings = ?, filters = ? WHERE id = ?`,
			cur.Name, cur.ADOProject, string(cur.Type), marshal(cur.Mappings), marshal(cur.Filters), cur.ID),
		stmt(`INSERT INTO job_activity (job_id, at, text) VALUES (?, ?, ?)`, cur.ID, a.At.UnixMilli(), a.Text),
	)
}

func (s *Store) DeleteJob(id int) {
	s.Jobs = slices.DeleteFunc(s.Jobs, func(j Job) bool { return j.ID == id })
	s.Runs = slices.DeleteFunc(s.Runs, func(r Run) bool { return r.JobID == id })
	s.write(stmt(`DELETE FROM jobs WHERE id = ?`, id)) // cascades to activity, runs and tickets
}

func (s *Store) SetStatus(id int, st Status) {
	j := s.Job(id)
	if j == nil || j.Status == st {
		return
	}
	j.Status = st
	a := Activity{At: s.now(), Text: map[Status]string{Active: "Job resumed", Paused: "Job paused"}[st]}
	j.Activity = append(j.Activity, a)
	s.write(
		stmt(`UPDATE jobs SET status = ? WHERE id = ?`, string(st), id),
		stmt(`INSERT INTO job_activity (job_id, at, text) VALUES (?, ?, ?)`, id, a.At.UnixMilli(), a.Text),
	)
}

func (s *Store) Log(id int, text string) {
	j := s.Job(id)
	if j == nil {
		return
	}
	a := Activity{At: s.now(), Text: text}
	j.Activity = append(j.Activity, a)
	s.write(stmt(`INSERT INTO job_activity (job_id, at, text) VALUES (?, ?, ?)`, id, a.At.UnixMilli(), a.Text))
}

func (s *Store) AddRun(r Run) int {
	s.nextRun++
	r.ID = s.nextRun
	s.Runs = slices.Insert(s.Runs, 0, r)
	stmts := []sqlite.Statement{stmt(`INSERT INTO runs (id, job_id, started, duration_ms, since, error) VALUES (?, ?, ?, ?, ?, ?)`,
		r.ID, r.JobID, r.Started.UnixMilli(), r.Duration.Milliseconds(), r.Since, r.Error)}
	for _, t := range r.Tickets {
		stmts = append(stmts, stmt(`INSERT INTO tickets (run_id, key, summary, outcome, error, calls, work_item_type, ado_id, message) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			r.ID, t.Key, t.Summary, string(t.Outcome), t.Error, marshal(orEmpty(t.Calls)), t.WorkItemType, t.ADOID, t.Message))
	}
	s.write(stmts...)
	return r.ID
}

func (s *Store) Run(id int) *Run {
	for i := range s.Runs {
		if s.Runs[i].ID == id {
			return &s.Runs[i]
		}
	}
	return nil
}

func (s *Store) RunsFor(jobID int) []Run {
	var out []Run
	for _, r := range s.Runs {
		if r.JobID == jobID {
			out = append(out, r)
		}
	}
	return out
}

func (s *Store) DeleteRuns(ids ...int) {
	s.Runs = slices.DeleteFunc(s.Runs, func(r Run) bool { return slices.Contains(ids, r.ID) })
	stmts := make([]sqlite.Statement, 0, len(ids))
	for _, id := range ids {
		stmts = append(stmts, stmt(`DELETE FROM runs WHERE id = ?`, id))
	}
	s.write(stmts...)
}

func (s *Store) LastRun(jobID int) (Run, bool) {
	for _, r := range s.Runs {
		if r.JobID == jobID {
			return r, true
		}
	}
	return Run{}, false
}

func marshal(v any) string {
	b, _ := json.Marshal(v) // only our own plain structs, which always marshal
	return string(b)
}

func unmarshal(v any, dst any) error {
	s, _ := v.(string)
	return json.Unmarshal([]byte(s), dst)
}

// orEmpty keeps "no calls" as [] rather than null in the database.
func orEmpty[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func toInt(v any) int {
	n, _ := v.(int64)
	return int(n)
}

func fromMillis(v any) time.Time {
	n, _ := v.(int64)
	return time.UnixMilli(n)
}

func (s *Store) SetSetting(key, value string) {
	if s.Settings[key] == value {
		return
	}
	s.Settings[key] = value
	s.write(stmt(`INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value))
}

// State returns the sync's own persistence; unlike the rest of Store it is safe from any goroutine.
func (s *Store) State() State {
	if s.db == nil {
		return s.mem
	}
	return sqlState{s.db}
}

type sqlState struct{ db *sqlite.DB }

func (q sqlState) Cursor(ctx context.Context, jobID int) (string, error) {
	rows, err := q.db.Query(ctx, `SELECT cursor FROM sync_state WHERE job_id = ?`, jobID)
	if err != nil || len(rows.Values) == 0 {
		return "", err
	}
	return rows.Values[0][0].(string), nil
}

func (q sqlState) SetCursor(ctx context.Context, jobID int, iso string) error {
	_, err := q.db.Execute(ctx, `INSERT INTO sync_state (job_id, cursor) VALUES (?, ?) ON CONFLICT(job_id) DO UPDATE SET cursor = excluded.cursor`, jobID, iso)
	return err
}

func (q sqlState) CommentMappings(ctx context.Context, workItemID int) (map[string]CommentMapping, error) {
	rows, err := q.db.Query(ctx, `SELECT jira_comment_id, ado_comment_id, jira_updated FROM comment_mappings WHERE ado_work_item_id = ?`, workItemID)
	if err != nil {
		return nil, err
	}
	out := make(map[string]CommentMapping, len(rows.Values))
	for _, r := range rows.Values {
		out[r[0].(string)] = CommentMapping{WorkItemID: workItemID, JiraCommentID: r[0].(string), ADOCommentID: toInt(r[1]), JiraUpdated: r[2].(string)}
	}
	return out, nil
}

func (q sqlState) SaveCommentMapping(ctx context.Context, m CommentMapping) error {
	_, err := q.db.Execute(ctx, `INSERT INTO comment_mappings (ado_work_item_id, jira_comment_id, ado_comment_id, jira_updated) VALUES (?, ?, ?, ?)
		ON CONFLICT(ado_work_item_id, jira_comment_id) DO UPDATE SET ado_comment_id = excluded.ado_comment_id, jira_updated = excluded.jira_updated`,
		m.WorkItemID, m.JiraCommentID, m.ADOCommentID, m.JiraUpdated)
	return err
}

type memState struct {
	mu       sync.Mutex
	cursors  map[int]string
	comments map[int]map[string]CommentMapping
}

func newMemState() *memState {
	return &memState{cursors: map[int]string{}, comments: map[int]map[string]CommentMapping{}}
}

func (m *memState) Cursor(_ context.Context, jobID int) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.cursors[jobID], nil
}

func (m *memState) SetCursor(_ context.Context, jobID int, iso string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cursors[jobID] = iso
	return nil
}

func (m *memState) CommentMappings(_ context.Context, workItemID int) (map[string]CommentMapping, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return maps.Clone(m.comments[workItemID]), nil
}

func (m *memState) SaveCommentMapping(_ context.Context, c CommentMapping) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.comments[c.WorkItemID] == nil {
		m.comments[c.WorkItemID] = map[string]CommentMapping{}
	}
	m.comments[c.WorkItemID][c.JiraCommentID] = c
	return nil
}

// firstWords names a failed batch in the log ("INSERT INTO runs") without its values.
func firstWords(stmts []sqlite.Statement) string {
	if len(stmts) == 0 {
		return ""
	}
	f := strings.Fields(stmts[0].SQL)
	return strings.Join(f[:min(3, len(f))], " ")
}
