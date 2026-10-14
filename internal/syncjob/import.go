package syncjob

import (
	"context"
	"fmt"
	"slices"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

// Import is data brought in from another install. Jobs carry provisional IDs that Runs, Cursors refer to;
// Store.Import renumbers them after the store's own.
type Import struct {
	Jobs     []Job
	Runs     []Run // oldest first
	Cursors  map[int]string
	Comments []CommentMapping
	Settings map[string]string
}

// Import writes everything in one transaction, so a failure leaves the store untouched.
func (s *Store) Import(ctx context.Context, im Import) error {
	if s.db == nil {
		return fmt.Errorf("import needs a database")
	}
	for _, j := range im.Jobs {
		if slices.ContainsFunc(s.Jobs, func(e Job) bool { return e.JiraKey == j.JiraKey }) {
			return fmt.Errorf("a job for Jira project %s already exists; delete it first so two jobs don't sync the same project", j.JiraKey)
		}
	}
	jobID := map[int]int{}
	jobs := make([]Job, len(im.Jobs))
	var stmts []sqlite.Statement
	next := s.nextJob
	for i, j := range im.Jobs {
		next++
		jobID[j.ID] = next
		j.ID = next
		jobs[i] = j
		stmts = append(stmts, stmt(`INSERT INTO jobs (id, name, jira_key, ado_project, type, status, created, mappings, filters) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			j.ID, j.Name, j.JiraKey, j.ADOProject, string(j.Type), string(j.Status), j.Created.UnixMilli(), marshal(j.Mappings), marshal(j.Filters)))
		for _, a := range j.Activity {
			stmts = append(stmts, stmt(`INSERT INTO job_activity (job_id, at, text) VALUES (?, ?, ?)`, j.ID, a.At.UnixMilli(), a.Text))
		}
	}
	runs := make([]Run, len(im.Runs))
	nextRun := s.nextRun
	for i, r := range im.Runs {
		id, ok := jobID[r.JobID]
		if !ok {
			return fmt.Errorf("run for unknown job %d", r.JobID)
		}
		nextRun++
		r.ID, r.JobID = nextRun, id
		runs[i] = r
		stmts = append(stmts, stmt(`INSERT INTO runs (id, job_id, started, duration_ms, since, error, kind) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			r.ID, r.JobID, r.Started.UnixMilli(), r.Duration.Milliseconds(), r.Since, r.Error, r.Kind))
		for _, t := range r.Tickets {
			stmts = append(stmts, stmt(`INSERT INTO tickets (run_id, key, summary, outcome, error, calls, work_item_type, ado_id, message) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				r.ID, t.Key, t.Summary, string(t.Outcome), t.Error, marshal(orEmpty(t.Calls)), t.WorkItemType, t.ADOID, t.Message))
		}
	}
	for old, cur := range im.Cursors {
		id, ok := jobID[old]
		if !ok {
			return fmt.Errorf("cursor for unknown job %d", old)
		}
		stmts = append(stmts, stmt(`INSERT INTO sync_state (job_id, cursor) VALUES (?, ?)`, id, cur))
	}
	for _, m := range im.Comments {
		stmts = append(stmts, stmt(`INSERT INTO comment_mappings (ado_work_item_id, jira_comment_id, ado_comment_id, jira_updated) VALUES (?, ?, ?, ?)
			ON CONFLICT(ado_work_item_id, jira_comment_id) DO NOTHING`, m.WorkItemID, m.JiraCommentID, m.ADOCommentID, m.JiraUpdated))
	}
	for k, v := range im.Settings {
		stmts = append(stmts, stmt(`INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, k, v))
	}
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	if _, err := s.db.Transaction(ctx, stmts); err != nil {
		return err
	}
	// Memory follows only after COMMIT.
	s.Jobs = append(s.Jobs, jobs...)
	slices.Reverse(runs)
	s.Runs = append(runs, s.Runs...)
	s.nextJob, s.nextRun = next, nextRun
	for k, v := range im.Settings {
		s.Settings[k] = v
	}
	return nil
}
