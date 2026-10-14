// Package syncer is the real Jira→ADO engine, ported from the source app's app/api/sync/jobs/[id]/run/route.ts.
package syncer

import (
	"context"
	"encoding/json"
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
	Search(ctx context.Context, jql string, fields []string) ([]jira.Issue, error)
	Comments(ctx context.Context, key string) ([]jira.Comment, error)
	Download(ctx context.Context, url string) ([]byte, error)
}

type adoAPI interface {
	FindByField(ctx context.Context, field, value string) (int, error)
	Fields(ctx context.Context, id int, fields []string) (map[string]any, error)
	Create(ctx context.Context, workItemType string, ops []ado.Op) (int, error)
	Update(ctx context.Context, id int, ops []ado.Op) error
	ParentRelation(parentID int) ado.Op
	RemoveAttachments(ctx context.Context, id int) error
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

const (
	typePBI  = "Product Backlog Item"
	typeTask = "Task"
)

// run is one sync's working state.
type run struct {
	e     *Engine
	conn  syncjob.Connection
	job   syncjob.Job
	jira  jiraAPI
	ado   adoAPI
	calls *[]syncjob.APICall // the current ticket's ADO calls
	// firstRun has no cursor: it imports the whole backlog, so Done items are skipped without a comment each.
	firstRun bool
	// sprintField is Jira's Sprint custom field, read when iterations follow the Jira sprint.
	sprintField string
}

func (e *Engine) Sync(ctx context.Context, conn syncjob.Connection, job syncjob.Job) (out syncjob.Run) {
	start := e.Now()
	out = syncjob.Run{JobID: job.ID, Started: start}
	// run ties every log line of this sync together; the run's DB id isn't known until the UI saves it.
	lg := slog.With("run", fmt.Sprintf("%d-%d", job.ID, start.Unix()), "job", job.ID, "jira", job.JiraKey, "ado", job.ADOProject)
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
	if m := conn.Missing(); m != "" {
		out.Error = "Not configured: " + m + " (Settings)"
		return out
	}
	conn.JiraKeyField = cmpOr(conn.JiraKeyField, syncjob.DefaultJiraKeyField)

	r := &run{e: e, conn: conn, job: job}
	r.jira, r.ado = e.clients(conn, job.ADOProject, func(c ado.Call) {
		if r.calls != nil {
			*r.calls = append(*r.calls, syncjob.APICall{Method: c.Method, URL: c.URL, Request: c.Request, Status: c.Status,
				Response: c.Response, Retries: c.Retries, Duration: c.Duration, Error: c.Error})
		}
	})

	since, err := e.State.Cursor(ctx, job.ID)
	if err != nil {
		out.Error = "read cursor: " + err.Error()
		return out
	}
	out.Since = since
	r.firstRun = since == ""
	if job.Filters.AutoPaths {
		// Without the Sprint field every issue would look out of sprint and be moved to the backlog, so stop instead.
		if r.sprintField, err = r.jira.SprintField(ctx); err != nil || r.sprintField == "" {
			out.Error = "Can't read Jira's Sprint field, so issues can't be placed by sprint"
			if err != nil {
				out.Error += ": " + err.Error()
			}
			return out
		}
	}
	issues, err := r.detect(ctx, since)
	if err != nil {
		out.Error = err.Error()
		return out
	}
	lg.Info("issues detected", "count", len(issues), "since", since, "first_run", r.firstRun)

	cp := newCheckpoint(issues)
	for _, is := range issues {
		if ctx.Err() != nil {
			out.Error = "stopped: " + ctx.Err().Error()
			return out // cursor stays at the last checkpoint, so the next run resumes here
		}
		t := r.process(ctx, is)
		out.Tickets = append(out.Tickets, t)
		if t.Outcome == syncjob.Failed {
			lg.Warn("ticket failed", "key", t.Key, "ado_id", t.ADOID, "type", t.WorkItemType, "err", t.Error)
		} else if strings.Contains(t.Message, " · ") { // attachment/comment warnings
			lg.Warn("ticket synced with warnings", "key", t.Key, "ado_id", t.ADOID, "msg", t.Message)
		}
		// Checkpoint per issue; a failed issue still advances it on purpose — its ticket result is the record to rerun.
		if iso := cp.advance(is.ID); iso != "" {
			if err := e.State.SetCursor(ctx, job.ID, iso); err != nil {
				lg.Error("save checkpoint", "cursor", iso, "err", err)
			}
		}
	}
	// Only close the window when something was processed: a broken query returning 0 issues must not swallow the backlog.
	if len(issues) > 0 {
		if err := e.State.SetCursor(ctx, job.ID, start.UTC().Format(time.RFC3339Nano)); err != nil {
			lg.Error("save cursor", "err", err)
		}
	}
	return out
}

// detect lists the issues to process: updated since the cursor, plus sub-tasks of those parents, parents first.
func (r *run) detect(ctx context.Context, since string) ([]jira.Issue, error) {
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
		// ponytail: formatted in UTC but Jira reads it in the account's time zone; east of UTC it only re-reads a few hours
		parts = append(parts, fmt.Sprintf(`updated >= "%s"`, parseJiraTime(since).UTC().Format("2006/01/02 15:04")))
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
