// Package syncer is the real Jira→ADO engine, ported from the source app's app/api/sync/jobs/[id]/run/route.ts.
package syncer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	"jira-ado/internal/ado"
	"jira-ado/internal/applog"
	"jira-ado/internal/httpx"
	"jira-ado/internal/jira"
	"jira-ado/internal/syncjob"
)

type jiraAPI interface {
	SprintField(ctx context.Context) (string, error)
	TimeZone(ctx context.Context) (*time.Location, error)
	Search(ctx context.Context, jql string, fields []string) ([]jira.Issue, error)
	Comments(ctx context.Context, key string) ([]jira.Comment, error)
	Download(ctx context.Context, url string) ([]byte, error)
}

type adoAPI interface {
	NodeExists(ctx context.Context, kind, path string) (bool, error)
	FindByField(ctx context.Context, field, value string) (int, error)
	Get(ctx context.Context, id int) (ado.WorkItem, error)
	Create(ctx context.Context, workItemType string, ops []ado.Op) (int, error)
	Update(ctx context.Context, id int, ops []ado.Op) error
	ParentRelation(parentID int) ado.Op
	RemoveAttachments(ctx context.Context, id int, rels []ado.Relation) error
	Attach(ctx context.Context, id int, name string, data []byte) error
	AddComment(ctx context.Context, id int, html string) (int, error)
	UpdateComment(ctx context.Context, id, commentID int, html string) error
}

// Engine implements syncjob.Engine. Each Sync builds its own clients, so concurrent runs never share a PAT or a log.
type Engine struct {
	State syncjob.State
	Now   func() time.Time
	// clients is swapped in tests for fakes.
	clients func(conn syncjob.Connection, project string, onCall func(ado.Call)) (jiraAPI, adoAPI)
}

func New(state syncjob.State, now func() time.Time) *Engine {
	return &Engine{State: state, Now: now, clients: realClients}
}

func realClients(conn syncjob.Connection, project string, onCall func(ado.Call)) (jiraAPI, adoAPI) {
	a := ado.New(conn.ADOOrg, project, conn.PAT)
	a.OnCall = onCall
	return jira.New(strings.TrimRight(conn.JiraURL, "/"), conn.JiraEmail, conn.JiraToken), a
}

func (e *Engine) ValidatePAT(ctx context.Context, org, pat string) (string, error) {
	return ado.ConnectionData(ctx, httpx.New("", ado.PATAuth(pat)), org)
}

func (e *Engine) CheckJira(ctx context.Context, conn syncjob.Connection) (string, error) {
	if conn.JiraURL == "" || conn.JiraEmail == "" || conn.JiraToken == "" {
		return "", fmt.Errorf("set the Jira URL, email and API token first")
	}
	return jira.New(strings.TrimRight(conn.JiraURL, "/"), conn.JiraEmail, conn.JiraToken).Myself(ctx)
}

// run is one sync's working state.
type run struct {
	e     *Engine
	conn  syncjob.Connection
	job   syncjob.Job
	jira  jiraAPI
	ado   adoAPI
	calls *[]syncjob.APICall // the current ticket's ADO calls
	state syncjob.State      // e.State, or a read-only view of it in a dry run
	rules syncjob.Rules      // value mappings, defaults filled in
	dry   bool
	// ids caches "KEY - id" → ADO work item for the run, so sub-tasks don't look up the same parent again.
	ids map[string]int
	// loc is the Jira account's time zone, which JQL dates are read in.
	loc *time.Location
	// firstRun has no cursor: it imports the whole backlog, so Done items are skipped without a comment each.
	firstRun bool
	// sprintField is Jira's Sprint custom field, read when iterations follow the Jira sprint.
	sprintField string
}

func (e *Engine) Sync(ctx context.Context, conn syncjob.Connection, job syncjob.Job, opts syncjob.RunOptions) (out syncjob.Run) {
	start := e.Now()
	out = syncjob.Run{JobID: job.ID, Started: start}
	switch {
	case opts.DryRun:
		out.Kind = syncjob.KindDryRun
	case len(opts.Keys) > 0:
		out.Kind = syncjob.KindRetry
	}
	// run ties every log line of this sync together; the run's DB id isn't known until the UI saves it.
	lg := slog.With("run", fmt.Sprintf("%d-%d", job.ID, start.Unix()), "job", job.ID, "jira", job.JiraKey, "ado", job.ADOProject, "kind", out.Kind)
	defer func() { // named result, so every return path, a panic included, gets the duration and a log line
		if p := recover(); p != nil {
			out.Error = applog.Recovered("sync", p, "job", job.ID).Error()
		}
		out.Duration = e.Now().Sub(start)
		attrs := []any{"since", out.Since, "duration", out.Duration.Round(time.Millisecond), "tickets", len(out.Tickets),
			"created", out.Count(syncjob.Created), "updated", out.Count(syncjob.Updated), "skipped", out.Count(syncjob.Skipped), "failed", out.Count(syncjob.Failed)}
		if out.Error != "" {
			lg.Error("sync failed", append(attrs, "err", out.Error)...)
		} else {
			lg.Info("sync done", attrs...)
		}
	}()
	lg.Info("sync start")
	r, err := e.newRun(conn, job, opts.DryRun)
	if err != nil {
		out.Error = err.Error()
		return out
	}

	moveCursor := len(opts.Keys) == 0 && !opts.DryRun
	since := ""
	if len(opts.Keys) == 0 {
		if since, err = r.state.Cursor(ctx, job.ID); err != nil {
			out.Error = "read cursor: " + err.Error()
			return out
		}
		r.firstRun = since == ""
	}
	out.Since = since
	// Preflight: anything here would fail every ticket, so stop before a single write.
	if problems, err := r.preflight(ctx); err != nil || len(problems) > 0 {
		out.Error = stopReason(ctx, err, problems)
		return out
	}
	var issues []jira.Issue
	if len(opts.Keys) > 0 {
		issues, err = r.byKeys(ctx, opts.Keys)
	} else {
		issues, err = r.detect(ctx, since)
	}
	if err != nil {
		out.Error = stopReason(ctx, err, nil)
		return out
	}
	lg.Info("issues detected", "count", len(issues), "since", since, "first_run", r.firstRun)

	report := func() {
		if opts.OnProgress != nil {
			opts.OnProgress(syncjob.Progress{Run: out.Snapshot(), Done: len(out.Tickets), Total: len(issues)})
		}
	}
	report()
	cp := newCheckpoint(issues)
	details := map[string]jira.Issue{}
	fetched := map[string]bool{} // in a batch that answered: missing from details means Jira filtered it out
	for i, is := range issues {
		if ctx.Err() != nil {
			out.Error = stopReason(ctx, ctx.Err(), nil)
			return out // cursor stays at the last checkpoint, so the next run resumes here
		}
		if i%detailBatch == 0 {
			r.fetchDetails(ctx, issues[i:min(i+detailBatch, len(issues))], details, fetched, lg)
		}
		t := r.process(ctx, is, details, fetched[is.ID])
		out.Tickets = append(out.Tickets, t)
		report()
		if t.Outcome == syncjob.Failed {
			lg.Warn("ticket failed", "key", t.Key, "ado_id", t.ADOID, "type", t.WorkItemType, "err", t.Error)
		} else if strings.Contains(t.Message, " · ") { // attachment/comment warnings
			lg.Warn("ticket synced with warnings", "key", t.Key, "ado_id", t.ADOID, "msg", t.Message)
		}
		// Checkpoint per issue; a failed issue still advances it on purpose — its ticket result is the record to rerun.
		if iso := cp.advance(is.ID); iso != "" && moveCursor {
			if err := r.state.SetCursor(ctx, job.ID, iso); err != nil {
				lg.Error("save checkpoint", "cursor", iso, "err", err)
			}
		}
	}
	// Only close the window when something was processed: a broken query returning 0 issues must not swallow the backlog.
	if len(issues) > 0 && moveCursor {
		if err := r.state.SetCursor(ctx, job.ID, start.UTC().Format(time.RFC3339Nano)); err != nil {
			lg.Error("save cursor", "err", err)
		}
	}
	return out
}

// newRun builds the clients and state of one run; in a dry run the ADO writes and the state writes are only recorded.
func (e *Engine) newRun(conn syncjob.Connection, job syncjob.Job, dry bool) (*run, error) {
	if m := conn.Missing(); m != "" {
		return nil, fmt.Errorf("Not configured: %s (Settings)", m)
	}
	conn.JiraKeyField = cmpOr(conn.JiraKeyField, syncjob.DefaultJiraKeyField)
	r := &run{e: e, conn: conn, job: job, state: e.State, rules: conn.Rules.OrDefault(), dry: dry, ids: map[string]int{}, loc: time.UTC}
	logCall := func(c ado.Call) {
		if r.calls != nil {
			*r.calls = append(*r.calls, syncjob.APICall{Method: c.Method, URL: c.URL, Request: c.Request, Status: c.Status,
				Response: c.Response, Retries: c.Retries, Duration: c.Duration, Error: c.Error})
		}
	}
	r.jira, r.ado = e.clients(conn, job.ADOProject, logCall)
	if dry {
		r.ado = &dryADO{adoAPI: r.ado, log: logCall}
		r.state = readOnlyState{e.State}
	}
	return r, nil
}

// Check is the preflight on its own, for the job editor.
func (e *Engine) Check(ctx context.Context, conn syncjob.Connection, job syncjob.Job) ([]string, error) {
	r, err := e.newRun(conn, job, true)
	if err != nil {
		return nil, err
	}
	return r.preflight(ctx)
}

// preflight lists what would fail every ticket: a missing area or iteration path, or no Sprint field to place issues by.
func (r *run) preflight(ctx context.Context) ([]string, error) {
	var problems []string
	f := r.job.Filters
	area, iteration := r.job.Paths(r.e.Now())
	paths := [][2]string{{"areas", area}}
	if f.AutoPaths {
		paths = append(paths, [2]string{"iterations", iteration}, [2]string{"iterations", r.job.BacklogPath()})
		// Without the Sprint field every issue would look out of sprint and be moved to the backlog.
		field, err := r.jira.SprintField(ctx)
		if err != nil {
			return nil, err
		}
		if field == "" {
			problems = append(problems, "Jira has no Sprint field this account can read, so issues can't be placed by sprint")
		}
		r.sprintField = field
	} else {
		paths = append(paths, [2]string{"iterations", iteration})
	}
	for _, p := range paths {
		if strings.TrimSpace(p[1]) == "" {
			problems = append(problems, "No "+strings.TrimSuffix(p[0], "s")+" path set")
			continue
		}
		ok, err := r.ado.NodeExists(ctx, p[0], p[1])
		if err != nil {
			return nil, err
		}
		if !ok {
			problems = append(problems, fmt.Sprintf("%s path %q doesn't exist in ADO project %s", map[string]string{"areas": "Area", "iterations": "Iteration"}[p[0]], p[1], r.job.ADOProject))
		}
	}
	return problems, nil
}

// stopReason says why a run stopped: cancelled, timed out, preflight problems, or the error.
func stopReason(ctx context.Context, err error, problems []string) string {
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		return "Cancelled"
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return "Stopped: the run took longer than its time limit"
	case len(problems) > 0:
		return "Preflight: " + strings.Join(problems, "; ") + ". Nothing was written."
	case err != nil:
		return err.Error()
	}
	return ""
}

// byKeys fetches just the given issues, for Retry failed.
func (r *run) byKeys(ctx context.Context, keys []string) ([]jira.Issue, error) {
	q := make([]string, len(keys))
	for i, k := range keys {
		q[i] = jqlQuote(k)
	}
	issues, err := r.jira.Search(ctx, "key in ("+strings.Join(q, ",")+") AND project = "+jqlQuote(r.job.JiraKey), searchFields)
	if err != nil {
		return nil, err
	}
	slices.SortStableFunc(issues, func(a, b jira.Issue) int { return boolInt(isSubtask(a)) - boolInt(isSubtask(b)) })
	return issues, nil
}

// detailBatch is how many issues one Jira search fetches in full; one search per issue was the source's N+1.
const detailBatch = 50

// fetchDetails loads the full fields of a batch; on failure the issues fall back to one search each in process.
func (r *run) fetchDetails(ctx context.Context, batch []jira.Issue, into map[string]jira.Issue, fetched map[string]bool, lg *slog.Logger) {
	ids := make([]string, len(batch))
	for i, is := range batch {
		ids[i] = is.ID
	}
	got, err := r.jira.Search(ctx, r.scopedJQL("id in ("+strings.Join(ids, ",")+")"), jira.AllFields)
	if err != nil {
		lg.Warn("batch detail fetch failed; fetching one by one", "issues", len(ids), "err", err)
		return
	}
	for _, d := range got {
		into[d.ID] = d
	}
	for _, id := range ids {
		fetched[id] = true
	}
}

// detect lists the issues to process: updated since the cursor, plus sub-tasks of those parents, parents first.
func (r *run) detect(ctx context.Context, since string) ([]jira.Issue, error) {
	if since != "" {
		loc, err := r.jira.TimeZone(ctx)
		if err != nil || loc == nil {
			slog.Warn("Jira time zone unknown; reading 12h further back so no issue is missed", "job", r.job.ID, "err", err)
			loc = nil
		}
		r.loc = loc
	}
	assignees := r.job.Filters.AssigneeList()
	if !r.job.Filters.UserFilter {
		assignees = nil
	}
	issues, err := r.jira.Search(ctx, r.searchJQL(since, assignees), searchFields)
	if err != nil {
		return nil, err
	}
	// Jira answers an empty 200 when it can't resolve a user in `assignee in`, so retry unfiltered and filter in the loop.
	if len(issues) == 0 && len(assignees) > 0 {
		all, err := r.jira.Search(ctx, r.searchJQL(since, nil), searchFields)
		if err != nil {
			return nil, err
		}
		if len(all) > 0 {
			slog.Warn("assignee filter matched nothing; refetched without it", "job", r.job.ID, "unfiltered", len(all), "assignees", assignees)
			issues = all
		}
	}

	// An updated parent doesn't mean its sub-tasks changed, so pull in sub-tasks the cursor would miss.
	known := map[string]bool{}
	for _, i := range issues {
		known[i.ID] = true
	}
	var missing []string
	for _, i := range issues {
		for _, s := range i.Fields.Subtasks {
			if !known[s.ID] {
				known[s.ID] = true
				missing = append(missing, s.ID)
			}
		}
	}
	if len(missing) > 0 {
		subs, err := r.jira.Search(ctx, "id in ("+strings.Join(missing, ",")+")", searchFields)
		if err != nil {
			return nil, err
		}
		issues = append(issues, subs...)
	}
	// Parents before sub-tasks, so a sub-task can link to its parent's work item.
	slices.SortStableFunc(issues, func(a, b jira.Issue) int { return boolInt(isSubtask(a)) - boolInt(isSubtask(b)) })
	return issues, nil
}

// searchFields adds issuetype and parent to the source app's id/subtasks/updated: its parents-first sort needs them.
var searchFields = []string{"id", "subtasks", "updated", "issuetype", "parent"}

func (r *run) searchJQL(since string, assignees []string) string {
	var parts []string
	if since != "" {
		parts = append(parts, fmt.Sprintf(`updated >= "%s"`, jqlTime(parseJiraTime(since), r.loc)))
	}
	parts = append(parts, "project = "+jqlQuote(r.job.JiraKey))
	if r.conn.JQLExtra != "" {
		parts = append(parts, "("+r.conn.JQLExtra+")")
	}
	if len(assignees) > 0 {
		q := make([]string, len(assignees))
		for i, a := range assignees {
			q[i] = jqlQuote(a)
		}
		parts = append(parts, "assignee in ("+strings.Join(q, ",")+")")
	}
	return strings.Join(parts, " AND ") + " ORDER BY updated ASC"
}

func jqlQuote(s string) string {
	b, _ := json.Marshal(s) // JQL strings take JSON-style escapes, as the source's JSON.stringify
	return string(b)
}

func isSubtask(i jira.Issue) bool {
	return (i.Fields.IssueType != nil && i.Fields.IssueType.Subtask) || i.Fields.Parent != nil
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func cmpOr(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// jqlTime writes t as Jira reads JQL dates: wall-clock time in the account's zone, to the minute (rounded down,
// so the window never starts late). Without a zone it goes 12h back: read in any zone (UTC-12…UTC+14) it starts no later than t.
func jqlTime(t time.Time, loc *time.Location) string {
	if loc == nil {
		return t.UTC().Add(-12 * time.Hour).Format("2006/01/02 15:04")
	}
	return t.In(loc).Format("2006/01/02 15:04")
}
