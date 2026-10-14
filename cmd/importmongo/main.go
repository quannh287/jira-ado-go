// Command importmongo imports the Next.js app's MongoDB data into this app's SQLite database. Stop the app first.
//
//	node cmd/importmongo/export.mjs ~/Development/OTHERS/jira-ado /tmp/export   # read-only, uses that repo's mongodb driver and .env
//	go run ./cmd/importmongo -export /tmp/export -db "$HOME/Library/Application Support/jira-ado Dev/jira-ado.db" -dry-run
package main

import (
	"cmp"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"jira-ado/internal/syncjob"
)

// Source app constants (route.ts, domain/entities/SyncJob.ts).
const (
	legacyCursorKey = "sync-jira-ado:lastSyncIso"
	legacyJobID     = "sync-1779880948202-di68j2mcg"
	maxLoggedBody   = 16 << 10
)

type mongoJob struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	JiraProjectKey string    `json:"jiraProjectKey"`
	ADOProjectID   string    `json:"adoProjectId"`
	Status         string    `json:"status"`
	SyncType       string    `json:"syncType"`
	CreatedAt      time.Time `json:"createdAt"`
	SyncComments   *bool     `json:"syncComments"`
	UserFilter     *struct {
		Enabled   bool     `json:"enabled"`
		JiraUsers []string `json:"jiraUsers"`
	} `json:"userFilter"`
	UserMappings []struct {
		JiraUser string `json:"jiraUser"`
		ADOEmail string `json:"adoEmail"`
	} `json:"userMappings"`
	ADOConfig *struct {
		AreaPath  string `json:"areaPath"`
		Iteration struct {
			Mode           string `json:"mode"`
			FixedPath      string `json:"fixedPath"`
			SprintRootPath string `json:"sprintRootPath"`
			AnchorSprint   int    `json:"anchorSprint"`
			AnchorDate     string `json:"anchorDate"`
		} `json:"iteration"`
	} `json:"adoConfig"`
}

type mongoRun struct {
	SyncRunID  string    `json:"syncRunId"`
	JobID      string    `json:"jobId"`
	StartedAt  time.Time `json:"startedAt"`
	FinishedAt time.Time `json:"finishedAt"`
	DurationMs int64     `json:"durationMs"`
	Status     string    `json:"status"`
	Since      string    `json:"since"`
	Error      string    `json:"error"`
}

type mongoTicket struct {
	SyncRunID     string          `json:"syncRunId"`
	JiraID        string          `json:"jiraID"`
	JiraKey       string          `json:"jiraKey"`
	WorkItemType  string          `json:"workItemType"`
	Action        string          `json:"action"`
	Status        string          `json:"status"`
	ADOWorkItemID int             `json:"adoWorkItemId"`
	Message       string          `json:"message"`
	Error         json.RawMessage `json:"error"`
	CreatedAt     time.Time       `json:"createdAt"`
}

type mongoLog struct {
	SyncRunID   string          `json:"syncRunId"`
	JiraID      string          `json:"jiraID"`
	WorkItemID  int             `json:"workItemId"`
	Method      string          `json:"method"`
	URL         string          `json:"url"`
	Request     json.RawMessage `json:"request"`
	Response    json.RawMessage `json:"response"`
	HTTPStatus  int             `json:"httpStatus"`
	Retries     int             `json:"retries"`
	DurationMs  int64           `json:"durationMs"`
	RequestedAt time.Time       `json:"requestedAt"`
	Error       *struct {
		Message string `json:"message"`
	} `json:"error"`
}

type mongoComment struct {
	ADOWorkItemID int    `json:"adoWorkItemId"`
	JiraCommentID string `json:"jiraCommentId"`
	ADOCommentID  int    `json:"adoCommentId"`
	JiraUpdatedAt string `json:"jiraUpdatedAt"`
}

func main() {
	export := flag.String("export", "", "directory written by export.mjs")
	dbPath := flag.String("db", "", "this app's SQLite database")
	dry := flag.Bool("dry-run", false, "convert and report, write nothing")
	flag.Parse()
	if *export == "" || *dbPath == "" {
		flag.Usage()
		os.Exit(2)
	}
	im, report, err := convert(*export)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Print(report)
	if *dry {
		return
	}
	store, err := syncjob.Open(*dbPath, time.Now)
	if err != nil {
		log.Fatal(err)
	}
	defer store.Close()
	if err := store.Import(context.Background(), im); err != nil {
		log.Fatalf("import: %v (nothing was written)", err)
	}
	fmt.Println("imported into", *dbPath)
}

func read[T any](dir, name string) []T {
	data, err := os.ReadFile(filepath.Join(dir, name+".json"))
	if err != nil {
		log.Fatal(err)
	}
	var out []T
	if err := json.Unmarshal(data, &out); err != nil {
		log.Fatalf("%s: %v", name, err)
	}
	return out
}

func convert(dir string) (syncjob.Import, string, error) {
	var settings map[string]string
	data, err := os.ReadFile(filepath.Join(dir, "settings.json"))
	if err != nil {
		return syncjob.Import{}, "", err
	}
	if err := json.Unmarshal(data, &settings); err != nil {
		return syncjob.Import{}, "", err
	}
	// The source engine ignored adoProjectId and used env ADO_PROJECT; keep what it actually synced to.
	project := settings["ADO_PROJECT"]

	var b strings.Builder
	im := syncjob.Import{Cursors: map[int]string{}, Settings: map[string]string{
		"ado_org": settings["ADO_ORG"], "jira_url": strings.TrimRight(settings["JIRA_BASE_URL"], "/"),
		"jira_email": settings["JIRA_EMAIL"], "jql_extra": settings["JIRA_JQL_EXTRA"],
		"jira_key_field": cmp.Or(settings["ADO_JIRA_KEY_FIELD"], syncjob.DefaultJiraKeyField),
	}}

	jobIndex := map[string]int{} // Mongo job id → provisional id
	for i, mj := range read[mongoJob](dir, "syncJobs") {
		id := i + 1
		jobIndex[mj.ID] = id
		im.Jobs = append(im.Jobs, toJob(id, mj, project))
		fmt.Fprintf(&b, "job %-28s %s → ADO %s (%s)\n", mj.Name, mj.JiraProjectKey, project, mj.Status)
	}

	states := read[struct {
		ID    string `json:"_id"`
		Value string `json:"value"`
	}](dir, "sync_state")
	cursor := map[string]string{}
	for _, s := range states {
		cursor[s.ID] = s.Value
	}
	for mid, id := range jobIndex {
		c := cursor[legacyCursorKey+":"+mid]
		if c == "" && mid == legacyJobID {
			c = cursor[legacyCursorKey] // the original SE job inherits the pre-multi-job key, as in the source
		}
		if c != "" {
			im.Cursors[id] = c
			fmt.Fprintf(&b, "cursor %s = %s\n", im.Jobs[id-1].JiraKey, c)
		} else {
			fmt.Fprintf(&b, "cursor %s: none — the first sync imports the whole backlog\n", im.Jobs[id-1].JiraKey)
		}
	}

	for _, c := range read[mongoComment](dir, "comment_mappings") {
		im.Comments = append(im.Comments, syncjob.CommentMapping{WorkItemID: c.ADOWorkItemID, JiraCommentID: c.JiraCommentID, ADOCommentID: c.ADOCommentID, JiraUpdated: c.JiraUpdatedAt})
	}

	ticketsByRun := map[string][]mongoTicket{}
	for _, t := range read[mongoTicket](dir, "sync_ticket_results") {
		ticketsByRun[t.SyncRunID] = append(ticketsByRun[t.SyncRunID], t)
	}
	logsByRun := map[string][]mongoLog{}
	for _, l := range read[mongoLog](dir, "ado_logs") {
		logsByRun[l.SyncRunID] = append(logsByRun[l.SyncRunID], l)
	}

	runs := read[mongoRun](dir, "sync_runs")
	slices.SortFunc(runs, func(a, b mongoRun) int { return a.StartedAt.Compare(b.StartedAt) })
	var nTickets, nCalls, unmatched, skippedRuns int
	for _, mr := range runs {
		jobID, ok := jobIndex[mr.JobID]
		if !ok {
			skippedRuns++
			continue
		}
		r := syncjob.Run{JobID: jobID, Started: mr.StartedAt, Since: mr.Since, Duration: time.Duration(mr.DurationMs) * time.Millisecond}
		if r.Duration == 0 && !mr.FinishedAt.IsZero() {
			r.Duration = mr.FinishedAt.Sub(mr.StartedAt)
		}
		switch mr.Status {
		case "failed":
			r.Error = cmp.Or(mr.Error, "failed")
		case "running":
			r.Error = "Interrupted: the run never finished"
		}
		logs := logsByRun[mr.SyncRunID]
		used := make([]bool, len(logs))
		for _, mt := range ticketsByRun[mr.SyncRunID] {
			t := toTicket(mt)
			link := mt.JiraKey + " - " + mt.JiraID
			for i, l := range logs {
				if !used[i] && (l.JiraID == link || (l.WorkItemID != 0 && l.WorkItemID == mt.ADOWorkItemID)) {
					used[i] = true
					t.Calls = append(t.Calls, toCall(l))
					if t.Summary == "" {
						t.Summary = summaryFrom(l.Request, link)
					}
				}
			}
			nCalls += len(t.Calls)
			r.Tickets = append(r.Tickets, t)
		}
		for _, u := range used {
			if !u {
				unmatched++
			}
		}
		nTickets += len(r.Tickets)
		im.Runs = append(im.Runs, r)
	}
	fmt.Fprintf(&b, "%d runs, %d tickets, %d ADO calls attached (%d calls matched no ticket and are dropped), %d comment mappings\n",
		len(im.Runs), nTickets, nCalls, unmatched, len(im.Comments))
	if skippedRuns > 0 {
		fmt.Fprintf(&b, "%d runs belong to deleted jobs and are skipped\n", skippedRuns)
	}
	return im, b.String(), nil
}

func toJob(id int, mj mongoJob, project string) syncjob.Job {
	f := syncjob.DefaultFilters()
	if mj.SyncComments != nil {
		f.SyncComments = *mj.SyncComments
	} else {
		f.SyncComments = false // the source's `job.syncComments ?? false`
	}
	if mj.UserFilter != nil {
		f.UserFilter = mj.UserFilter.Enabled
		f.Assignees = strings.Join(mj.UserFilter.JiraUsers, ", ")
	}
	for _, u := range mj.UserMappings {
		f.Users = append(f.Users, syncjob.UserPair{Jira: u.JiraUser, ADOEmail: u.ADOEmail})
	}
	if c := mj.ADOConfig; c != nil {
		f.AreaPath = cmp.Or(c.AreaPath, syncjob.DefaultAreaPath)
		it := c.Iteration
		f.AutoPaths = !(it.Mode == "fixed" && it.FixedPath != "")
		f.Iteration = it.FixedPath
		f.SprintRoot = cmp.Or(it.SprintRootPath, syncjob.DefaultSprintRoot)
		f.AnchorSprint = cmp.Or(it.AnchorSprint, syncjob.DefaultAnchorSprint)
		f.AnchorDate = cmp.Or(it.AnchorDate, syncjob.DefaultAnchorDate)
	}
	status := syncjob.Active
	if mj.Status != "ACTIVE" {
		status = syncjob.Paused
	}
	typ := syncjob.Manual
	switch strings.ToLower(mj.SyncType) {
	case "scheduler", "scheduled":
		typ = syncjob.Scheduler
	case "webhook":
		typ = syncjob.Webhook
	}
	return syncjob.Job{
		ID: id, Name: mj.Name, JiraKey: mj.JiraProjectKey, ADOProject: project, Type: typ, Status: status,
		// The source ignored fieldMappings and always wrote every field, which is SmartDefaults here.
		Mappings: syncjob.SmartDefaults(), Filters: f, Created: mj.CreatedAt,
		Activity: []syncjob.Activity{
			{At: mj.CreatedAt, Text: "Job created"},
			{At: time.Now(), Text: "Imported from the Next.js app (MongoDB job " + mj.ID + ")"},
		},
	}
}

func toTicket(mt mongoTicket) syncjob.Ticket {
	t := syncjob.Ticket{Key: mt.JiraKey, WorkItemType: mt.WorkItemType, ADOID: mt.ADOWorkItemID, Message: mt.Message}
	switch {
	case mt.Status == "error" || mt.Action == "error":
		t.Outcome, t.Message = syncjob.Failed, ""
		t.Error = mt.Message
		if len(mt.Error) > 0 && string(mt.Error) != "null" {
			t.Error += "\n" + clip(pretty(mt.Error))
		}
	case mt.Action == "create":
		t.Outcome = syncjob.Created
	case mt.Action == "update":
		t.Outcome = syncjob.Updated
	default:
		t.Outcome = syncjob.Skipped
	}
	return t
}

func toCall(l mongoLog) syncjob.APICall {
	c := syncjob.APICall{Method: l.Method, URL: l.URL, Request: clip(pretty(l.Request)), Status: l.HTTPStatus,
		Response: clip(pretty(l.Response)), Retries: l.Retries, Duration: time.Duration(l.DurationMs) * time.Millisecond}
	if l.Error != nil {
		c.Error = l.Error.Message
	}
	return c
}

// summaryFrom recovers the Jira summary from the "KEY - id - summary" title the source sent to ADO.
func summaryFrom(request json.RawMessage, link string) string {
	var ops []struct {
		Path  string `json:"path"`
		Value any    `json:"value"`
	}
	if json.Unmarshal(request, &ops) != nil {
		return ""
	}
	for _, op := range ops {
		if op.Path == "/fields/"+syncjob.FieldTitle {
			if s, ok := op.Value.(string); ok {
				return strings.TrimPrefix(s, link+" - ")
			}
		}
	}
	return ""
}

func pretty(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var v any
	if json.Unmarshal(raw, &v) != nil {
		return string(raw)
	}
	out, _ := json.MarshalIndent(v, "", "  ")
	return string(out)
}

func clip(s string) string {
	if len(s) > maxLoggedBody {
		return s[:maxLoggedBody] + "\n…(truncated)"
	}
	return s
}
