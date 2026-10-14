package syncer

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"testing"
	"time"

	"jira-ado/internal/ado"
	"jira-ado/internal/jira"
	"jira-ado/internal/syncjob"
)

var t0 = time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)

// fakeJira serves issues by id; the project search returns all of them unless assigneeBlind hides them.
type fakeJira struct {
	issues        []jira.Issue
	comments      map[string][]jira.Comment
	jqls          []string
	assigneeBlind bool // Jira can't resolve the users in `assignee in` and answers empty
	failDetail    string
	noSprintField bool
}

const sprintField = "customfield_10020"

func (f *fakeJira) SprintField(context.Context) (string, error) {
	if f.noSprintField {
		return "", nil
	}
	return sprintField, nil
}

// inSprint puts an issue in a Jira sprint with the given state ("" = no sprint).
func inSprint(i *jira.Issue, state string) {
	if i.Raw == nil {
		i.Raw = map[string]json.RawMessage{}
	}
	i.Raw[sprintField] = json.RawMessage("null")
	if state != "" {
		i.Raw[sprintField] = json.RawMessage(`[{"id":1,"state":"` + state + `"}]`)
	}
}

var idIn = regexp.MustCompile(`id in \(([^)]*)\)`)
var keyIn = regexp.MustCompile(`key in \(([^)]*)\)`)
var idEq = regexp.MustCompile(`^id = (\d+)`)

func (f *fakeJira) Search(_ context.Context, jql string, _ []string) ([]jira.Issue, error) {
	f.jqls = append(f.jqls, jql)
	if m := idEq.FindStringSubmatch(jql); m != nil {
		if m[1] == f.failDetail {
			return nil, errors.New("jira 500")
		}
		return f.byID(m[1]), nil
	}
	if m := keyIn.FindStringSubmatch(jql); m != nil {
		var out []jira.Issue
		for _, k := range strings.Split(m[1], ",") {
			for _, i := range f.issues {
				if `"`+i.Key+`"` == strings.TrimSpace(k) {
					out = append(out, i)
				}
			}
		}
		return out, nil
	}
	if m := idIn.FindStringSubmatch(jql); m != nil {
		var out []jira.Issue
		for _, id := range strings.Split(m[1], ",") {
			out = append(out, f.byID(id)...)
		}
		return out, nil
	}
	if f.assigneeBlind && strings.Contains(jql, "assignee in") {
		return nil, nil
	}
	var out []jira.Issue
	for _, i := range f.issues {
		if i.Fields.Parent == nil { // the project search returns parents; sub-tasks come via backfill
			out = append(out, i)
		}
	}
	return out, nil
}

func (f *fakeJira) byID(id string) []jira.Issue {
	for _, i := range f.issues {
		if i.ID == id {
			return []jira.Issue{i}
		}
	}
	return nil
}

func (f *fakeJira) Comments(_ context.Context, key string) ([]jira.Comment, error) {
	return f.comments[key], nil
}

func (f *fakeJira) Download(context.Context, string) ([]byte, error) { return []byte("file"), nil }

type item struct {
	typ      string
	fields   map[string]any
	parent   int
	comments map[int]string
	attached []string
}

// fakeADO is an in-memory ADO that enforces the state rules the sync works around.
type fakeADO struct {
	missing       map[string]bool // classification paths that don't exist
	panicOnCreate bool
	items         map[int]*item
	next          int
	keyFld        string
}

func newFakeADO() *fakeADO {
	return &fakeADO{items: map[int]*item{}, next: 100, keyFld: syncjob.DefaultJiraKeyField}
}

func (a *fakeADO) NodeExists(_ context.Context, _, path string) (bool, error) {
	return !a.missing[path], nil
}

func (a *fakeADO) FindByField(_ context.Context, field, value string) (int, error) {
	for id, it := range a.items {
		if it.fields[field] == value {
			return id, nil
		}
	}
	return 0, nil
}

func (a *fakeADO) Fields(_ context.Context, id int, _ []string) (map[string]any, error) {
	return a.items[id].fields, nil
}

func (a *fakeADO) Create(_ context.Context, typ string, ops []ado.Op) (int, error) {
	if a.panicOnCreate {
		panic("nil map write in a client")
	}
	a.next++
	it := &item{typ: typ, fields: map[string]any{}, comments: map[int]string{}}
	if err := a.apply(it, ops, true); err != nil {
		return 0, err
	}
	a.items[a.next] = it
	return a.next, nil
}

func (a *fakeADO) Update(_ context.Context, id int, ops []ado.Op) error {
	return a.apply(a.items[id], ops, false)
}

func (a *fakeADO) apply(it *item, ops []ado.Op, creating bool) error {
	for _, op := range ops {
		if op.Path == "/relations/-" {
			rel := op.Value.(map[string]string)
			if rel["rel"] == "System.LinkTypes.Hierarchy-Reverse" {
				it.parent = 1
			}
			continue
		}
		field := strings.TrimPrefix(op.Path, "/fields/")
		if field == syncjob.FieldState {
			s := op.Value.(string)
			if creating && s != "New" && s != "To Do" {
				return errors.New("400: cannot create in state " + s)
			}
			if it.fields[field] == "Removed" && s != "New" && s != "To Do" {
				return errors.New("400: Removed can only move to the first state")
			}
		}
		it.fields[field] = op.Value
	}
	return nil
}

func (a *fakeADO) ParentRelation(parentID int) ado.Op {
	return ado.Op{Op: "add", Path: "/relations/-", Value: map[string]string{"rel": "System.LinkTypes.Hierarchy-Reverse"}}
}

func (a *fakeADO) RemoveAttachments(_ context.Context, id int) error {
	a.items[id].attached = nil
	return nil
}

func (a *fakeADO) Attach(_ context.Context, id int, name string, _ []byte) error {
	a.items[id].attached = append(a.items[id].attached, name)
	return nil
}

func (a *fakeADO) AddComment(_ context.Context, id int, html string) (int, error) {
	it := a.items[id]
	cid := len(it.comments) + 1
	it.comments[cid] = html
	return cid, nil
}

func (a *fakeADO) UpdateComment(_ context.Context, id, cid int, html string) error {
	a.items[id].comments[cid] = html
	return nil
}

var conn = syncjob.Connection{ADOOrg: "org", PAT: "pat", JiraURL: "https://x.atlassian.net", JiraEmail: "e", JiraToken: "t"}

func issue(id, key, status string, parent *jira.Ref, updated string) jira.Issue {
	typ := &struct {
		Name    string `json:"name"`
		Subtask bool   `json:"subtask"`
	}{Name: "Story"}
	if parent != nil {
		typ.Name, typ.Subtask = "Sub-task", true
	}
	return jira.Issue{ID: id, Key: key, Fields: jira.Fields{
		Summary: key + " summary", Created: "2026-10-01T10:00:00.000+0700", Updated: updated,
		Status: &struct {
			Name string `json:"name"`
		}{status},
		Priority: &struct {
			Name string `json:"name"`
		}{"High"},
		IssueType: typ, Parent: parent,
		Assignee:    &jira.User{EmailAddress: "dev@kai.example", DisplayName: "Dev"},
		Description: []byte(`{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"a<b","marks":[{"type":"strong"}]}]}]}`),
	}}
}

func setup() (*Engine, *fakeJira, *fakeADO, syncjob.State, syncjob.Job) {
	parent := issue("10", "SE-1", "In Progress", nil, "2026-10-10T10:00:00.000+0700")
	parent.Fields.Subtasks = []jira.Ref{{ID: "11", Key: "SE-2"}}
	inSprint(&parent, "active") // the sub-task stays out of any sprint
	sub := issue("11", "SE-2", "To Do", &jira.Ref{ID: "10", Key: "SE-1"}, "2026-10-02T10:00:00.000+0700")
	sub.Fields.AggregateTimeOriginalEstimate = 7200
	j := &fakeJira{issues: []jira.Issue{parent, sub}, comments: map[string][]jira.Comment{}}
	a := newFakeADO()
	state := syncjob.NewStore(func() time.Time { return t0 }).State()
	e := New(state, func() time.Time { return t0 })
	e.clients = func(syncjob.Connection, string, func(ado.Call)) (jiraAPI, adoAPI) { return j, a }
	f := syncjob.DefaultFilters()
	f.Users = []syncjob.UserPair{{Jira: "DEV@kai.example", ADOEmail: "dev@ado.example"}}
	job := syncjob.Job{ID: 1, JiraKey: "SE", ADOProject: "kai", Mappings: syncjob.SmartDefaults(), Filters: f}
	return e, j, a, state, job
}

func TestFirstRunCreatesParentsThenSubtasks(t *testing.T) {
	e, j, a, state, job := setup()
	run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{})
	if run.Error != "" || run.Status() != syncjob.Success {
		t.Fatalf("run error %q status %s tickets %+v", run.Error, run.Status(), run.Tickets)
	}
	if strings.Contains(j.jqls[0], "updated >=") {
		t.Fatalf("first run must import the whole backlog, got %q", j.jqls[0])
	}
	if run.Tickets[1].ParentKey != "SE-1" || run.Tickets[0].ParentKey != "" {
		t.Fatalf("parent keys %q %q", run.Tickets[0].ParentKey, run.Tickets[1].ParentKey)
	}
	if len(run.Tickets) != 2 || run.Tickets[0].Key != "SE-1" || run.Count(syncjob.Created) != 2 {
		t.Fatalf("tickets %+v", run.Tickets)
	}
	pbi := a.items[run.Tickets[0].ADOID]
	task := a.items[run.Tickets[1].ADOID]
	if pbi.typ != "Product Backlog Item" || pbi.fields[syncjob.FieldState] != "In Progress" || pbi.fields[syncjob.FieldPriority] != "2" {
		t.Fatalf("pbi %+v", pbi)
	}
	if pbi.fields[syncjob.FieldTitle] != "SE-1 - 10 - SE-1 summary" || pbi.fields[syncjob.FieldAssignedTo] != "dev@ado.example" {
		t.Fatalf("pbi fields %+v", pbi.fields)
	}
	if pbi.fields[syncjob.FieldDescription] != "<p><strong>a&lt;b</strong></p>" {
		t.Fatalf("description %q", pbi.fields[syncjob.FieldDescription])
	}
	if pbi.fields["System.IterationPath"] != `Tickets\Weekly Sprint\Sprint 82` || pbi.fields["System.AreaPath"] != syncjob.DefaultAreaPath {
		t.Fatalf("iteration %q", pbi.fields["System.IterationPath"])
	}
	if task.fields["System.IterationPath"] != `Tickets\Weekly Sprint` {
		t.Fatalf("out-of-sprint task iteration %q, want the backlog", task.fields["System.IterationPath"])
	}
	if task.typ != "Task" || task.parent == 0 || task.fields[syncjob.FieldOriginalEstimate] != 2.0 {
		t.Fatalf("task %+v", task)
	}
	if cur, _ := state.Cursor(context.Background(), 1); cur != t0.Format(time.RFC3339Nano) {
		t.Fatalf("cursor %q", cur)
	}

	// The next run only asks for issues updated since the cursor.
	e.Sync(context.Background(), conn, job, syncjob.RunOptions{})
	if !strings.HasPrefix(j.jqls[4], `updated >= "2026/10/14 09:00" AND project = "SE"`) {
		t.Fatalf("second run JQLs %q", j.jqls)
	}
}

func TestExistingItemRules(t *testing.T) {
	e, _, a, _, job := setup()
	first := e.Sync(context.Background(), conn, job, syncjob.RunOptions{})
	pbiID, taskID := first.Tickets[0].ADOID, first.Tickets[1].ADOID

	a.items[pbiID].fields[syncjob.FieldState] = "Done"
	a.items[taskID].fields[syncjob.FieldState] = "Removed"
	a.items[taskID].fields[syncjob.FieldOriginalEstimate] = 5.0 // filled in ADO: must be kept
	a.items[pbiID].fields[syncjob.FieldTitle] = "edited in ADO"

	run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{})
	pbi, task := run.Tickets[0], run.Tickets[1]
	if pbi.Outcome != syncjob.Skipped || a.items[pbiID].fields[syncjob.FieldTitle] != "edited in ADO" || len(a.items[pbiID].comments) != 1 {
		t.Fatalf("Done item was overwritten: %+v %+v", pbi, a.items[pbiID])
	}
	if task.Outcome != syncjob.Updated || a.items[taskID].fields[syncjob.FieldState] != "To Do" {
		t.Fatalf("Removed item not reactivated: %+v %+v", task, a.items[taskID].fields)
	}
	if a.items[taskID].fields[syncjob.FieldOriginalEstimate] != 5.0 {
		t.Fatalf("preserved estimate overwritten: %v", a.items[taskID].fields[syncjob.FieldOriginalEstimate])
	}
	c := a.items[taskID].comments[1]
	if !strings.Contains(c, "OriginalEstimate: ADO <b>5</b> — Jira <b>2</b>") {
		t.Fatalf("conflict comment %q", c)
	}
}

func TestUserFilterAndBlindAssigneeSearch(t *testing.T) {
	e, j, _, _, job := setup()
	job.Filters.Assignees = "someone else"
	j.assigneeBlind = true
	run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{})
	if run.Count(syncjob.Skipped) != 2 {
		t.Fatalf("assignee filter: %+v", run.Tickets)
	}
	if !strings.Contains(j.jqls[0], `assignee in ("someone else")`) || strings.Contains(j.jqls[1], "assignee in") {
		t.Fatalf("expected a filtered then an unfiltered search, got %q", j.jqls[:2])
	}

	// Filter on with no names: the assignee must resolve through the user mapping.
	e2, _, _, _, job2 := setup()
	job2.Filters.Users = nil
	if run := e2.Sync(context.Background(), conn, job2, syncjob.RunOptions{}); run.Count(syncjob.Skipped) != 2 {
		t.Fatalf("unmapped assignees synced: %+v", run.Tickets)
	}
}

func TestFailedTicketMakesRunPartial(t *testing.T) {
	e, j, _, state, job := setup()
	j.failDetail = "11"
	run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{})
	if run.Status() != syncjob.Partial || run.Tickets[1].Outcome != syncjob.Failed || run.Tickets[1].Error == "" {
		t.Fatalf("run %s tickets %+v", run.Status(), run.Tickets)
	}
	if cur, _ := state.Cursor(context.Background(), 1); cur == "" {
		t.Fatal("cursor must still advance past a failed ticket")
	}
}

func TestComments(t *testing.T) {
	e, j, a, _, job := setup()
	j.comments["SE-1"] = []jira.Comment{{ID: "c1", Author: &jira.User{DisplayName: "Ana"}, Updated: "u1",
		Body: []byte(`{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"hi"}]}]}`)}}
	id := e.Sync(context.Background(), conn, job, syncjob.RunOptions{}).Tickets[0].ADOID
	if got := a.items[id].comments[1]; got != "<div><p><strong>[Ana]:</strong></p><p>hi</p></div>" {
		t.Fatalf("comment %q", got)
	}
	e.Sync(context.Background(), conn, job, syncjob.RunOptions{}) // unchanged: no duplicate
	if len(a.items[id].comments) != 1 {
		t.Fatalf("comment duplicated: %v", a.items[id].comments)
	}
	j.comments["SE-1"][0].Updated = "u2"
	e.Sync(context.Background(), conn, job, syncjob.RunOptions{})
	if got := a.items[id].comments[1]; !strings.Contains(got, "(edited)") || len(a.items[id].comments) != 1 {
		t.Fatalf("edited comment not patched in place: %v", a.items[id].comments)
	}
}

func TestSprintPlacement(t *testing.T) {
	e, j, a, _, job := setup()
	id := e.Sync(context.Background(), conn, job, syncjob.RunOptions{}).Tickets[0].ADOID
	if a.items[id].fields["System.IterationPath"] != `Tickets\Weekly Sprint\Sprint 82` {
		t.Fatalf("active sprint → %q", a.items[id].fields["System.IterationPath"])
	}
	// Taken out of the sprint in Jira (a future sprint counts as out): back to the backlog.
	inSprint(&j.issues[0], "future")
	e.Sync(context.Background(), conn, job, syncjob.RunOptions{})
	if a.items[id].fields["System.IterationPath"] != `Tickets\Weekly Sprint` {
		t.Fatalf("left the sprint → %q, want the backlog", a.items[id].fields["System.IterationPath"])
	}

	// Without a Sprint field nothing is written: everything would otherwise drop to the backlog.
	e2, j2, a2, _, job2 := setup()
	j2.noSprintField = true
	run := e2.Sync(context.Background(), conn, job2, syncjob.RunOptions{})
	if run.Status() != syncjob.Error || len(a2.items) != 0 || !strings.Contains(run.Error, "Sprint field") {
		t.Fatalf("run %+v items %d", run, len(a2.items))
	}
	// A fixed iteration doesn't need it.
	job2.Filters.AutoPaths, job2.Filters.Iteration = false, `Tickets\Fixed`
	if run := e2.Sync(context.Background(), conn, job2, syncjob.RunOptions{}); run.Error != "" || a2.items[run.Tickets[0].ADOID].fields["System.IterationPath"] != `Tickets\Fixed` {
		t.Fatalf("fixed iteration run %+v", run)
	}
}

func TestFirstRunDoesNotCommentDoneItems(t *testing.T) {
	e, _, a, state, job := setup()
	id := e.Sync(context.Background(), conn, job, syncjob.RunOptions{}).Tickets[0].ADOID
	a.items[id].fields[syncjob.FieldState] = "Done"
	state.SetCursor(context.Background(), job.ID, "") // as if this were the job's first run
	run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{})
	if run.Tickets[0].Outcome != syncjob.Skipped || len(a.items[id].comments) != 0 || !strings.Contains(run.Tickets[0].Message, "first run") {
		t.Fatalf("first run commented a Done item: %+v comments %v", run.Tickets[0], a.items[id].comments)
	}
}

func TestPanicBecomesFailedRun(t *testing.T) {
	e, _, a, _, job := setup()
	a.panicOnCreate = true
	run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{}) // must not take the app down
	if run.Status() != syncjob.Error || !strings.Contains(run.Error, "internal error in sync") || run.Duration < 0 {
		t.Fatalf("run %+v", run)
	}
}

func TestProgress(t *testing.T) {
	e, _, _, _, job := setup()
	var got []syncjob.Progress
	run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{OnProgress: func(p syncjob.Progress) { got = append(got, p) }})
	if len(got) != 3 || got[0].Total != 2 || got[0].Done != 0 || got[2].Done != 2 || len(got[2].Run.Tickets) != 2 {
		t.Fatalf("progress %+v", got)
	}
	// Snapshots are copies: later appends never show up in an earlier one.
	if len(got[1].Run.Tickets) != 1 || got[1].Run.Tickets[0].Key != run.Tickets[0].Key {
		t.Fatalf("snapshot %+v", got[1].Run.Tickets)
	}
}

func TestPreflightStopsBeforeWriting(t *testing.T) {
	e, _, a, state, job := setup()
	a.missing = map[string]bool{syncjob.DefaultAreaPath: true}
	run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{})
	if run.Status() != syncjob.Error || !strings.Contains(run.Error, "Area path") || !strings.Contains(run.Error, "Nothing was written") || len(a.items) != 0 {
		t.Fatalf("run %+v items %d", run, len(a.items))
	}
	if cur, _ := state.Cursor(context.Background(), job.ID); cur != "" {
		t.Fatalf("cursor moved to %q", cur)
	}
	problems, err := e.Check(context.Background(), conn, job)
	if err != nil || len(problems) != 1 {
		t.Fatalf("Check = %q, %v", problems, err)
	}
}

func TestDryRunWritesNothing(t *testing.T) {
	e, j, a, state, job := setup()
	j.comments["SE-1"] = []jira.Comment{{ID: "c1", Author: &jira.User{DisplayName: "Ana"}, Updated: "u1"}}
	j.issues[0].Fields.Attachment = []jira.Attachment{{Filename: "log.txt", Content: "https://x/att/1"}}
	run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{DryRun: true})
	if run.Kind != syncjob.KindDryRun || run.Error != "" || run.Count(syncjob.Created) != 2 || len(a.items) != 0 {
		t.Fatalf("dry run %+v, %d items written", run, len(a.items))
	}
	if cur, _ := state.Cursor(context.Background(), job.ID); cur != "" {
		t.Fatalf("dry run moved the cursor to %q", cur)
	}
	if m, _ := state.CommentMappings(context.Background(), 0); len(m) != 0 {
		t.Fatalf("dry run saved comment mappings %v", m)
	}
	var held int
	for _, c := range run.Tickets[0].Calls {
		if c.Response == notSent {
			held++
		}
	}
	// create + comment + remove attachments + attach
	if held < 4 || !strings.HasPrefix(run.Tickets[0].Message, "Would create") {
		t.Fatalf("held %d calls, message %q: %+v", held, run.Tickets[0].Message, run.Tickets[0].Calls)
	}
}

func TestRetryOnlyGivenKeys(t *testing.T) {
	e, j, a, state, job := setup()
	run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{Keys: []string{"SE-2"}})
	if run.Kind != syncjob.KindRetry || len(run.Tickets) != 1 || run.Tickets[0].Key != "SE-2" || len(a.items) != 1 {
		t.Fatalf("retry %+v", run)
	}
	if !strings.Contains(j.jqls[0], `key in ("SE-2")`) {
		t.Fatalf("retry JQL %q", j.jqls[0])
	}
	if cur, _ := state.Cursor(context.Background(), job.ID); cur != "" {
		t.Fatalf("retry moved the cursor to %q", cur)
	}
}

func TestCancelled(t *testing.T) {
	e, _, a, _, job := setup()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	run := e.Sync(ctx, conn, job, syncjob.RunOptions{})
	if run.Error != "Cancelled" || len(a.items) != 0 {
		t.Fatalf("run %+v items %d", run, len(a.items))
	}
}

func TestCustomRules(t *testing.T) {
	e, j, a, _, job := setup()
	j.issues[0].Fields.IssueType.Name = "Bug"
	j.issues[0].Fields.Status.Name = "QA"
	j.issues[0].Fields.Priority.Name = "Blocker"
	c := conn
	c.Rules = syncjob.Rules{
		Types:      map[string]string{"bug": "Bug"},
		States:     map[string]string{"qa": "Verify Test"},
		Priorities: map[string]string{"Blocker": "1"},
	}
	id := e.Sync(context.Background(), c, job, syncjob.RunOptions{}).Tickets[0].ADOID
	it := a.items[id]
	if it.typ != "Bug" || it.fields[syncjob.FieldState] != "Verify Test" || it.fields[syncjob.FieldPriority] != "1" {
		t.Fatalf("rules not applied: %s %+v", it.typ, it.fields)
	}
	// Unmapped values fall back like the source: the type's first state, priority 4.
	if got := c.Rules.OrDefault().State("Bug", "Weird"); got != "New" {
		t.Fatalf("fallback state %q", got)
	}
}

func TestDurationRecorded(t *testing.T) {
	e, _, _, _, job := setup()
	clock := t0
	e.Now = func() time.Time { clock = clock.Add(time.Second); return clock }
	if run := e.Sync(context.Background(), conn, job, syncjob.RunOptions{}); run.Duration <= 0 {
		t.Fatalf("duration %v", run.Duration)
	}
}

func TestNotConfigured(t *testing.T) {
	e, _, _, _, job := setup()
	run := e.Sync(context.Background(), syncjob.Connection{ADOOrg: "org", PAT: "p"}, job, syncjob.RunOptions{})
	if run.Status() != syncjob.Error || !strings.Contains(run.Error, "Jira URL") {
		t.Fatalf("run %+v", run)
	}
}

func TestCheckpoint(t *testing.T) {
	is := func(id, updated string) jira.Issue { return jira.Issue{ID: id, Fields: jira.Fields{Updated: updated}} }
	cp := newCheckpoint([]jira.Issue{
		is("parent", "2026-10-03T00:00:00.000+0000"),
		is("old-sub", "2026-10-01T00:00:00.000+0000"),
		is("mid", "2026-10-02T00:00:00.000+0000"),
	})
	if got := cp.advance("parent"); got != "" {
		t.Fatalf("watermark passed unprocessed older issues: %q", got)
	}
	if got := cp.advance("old-sub"); got != "2026-10-01T00:00:00.000+0000" {
		t.Fatalf("after old-sub: %q", got)
	}
	if got := cp.advance("mid"); got != "2026-10-03T00:00:00.000+0000" {
		t.Fatalf("after all: %q", got)
	}
}

func TestSprintNumber(t *testing.T) {
	cases := map[string]int{"2026-06-01": 63, "2026-06-07": 63, "2026-06-08": 64, "2026-10-14": 82, "2026-05-31": 62}
	for day, want := range cases {
		d, _ := time.Parse("2006-01-02", day)
		if got := syncjob.SprintNumber(63, "2026-06-01", d.Add(15*time.Hour)); got != want {
			t.Errorf("%s: sprint %d, want %d", day, got, want)
		}
	}
}

func TestADFToHTML(t *testing.T) {
	in := `{"type":"doc","content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"T"}]},
		{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[
			{"type":"text","text":"go","marks":[{"type":"link","attrs":{"href":"https://x?a=1&b=2"}}]},{"type":"hardBreak"},
			{"type":"mention","attrs":{"text":"@Ana"}}]}]}]},{"type":"mediaSingle","content":[{"type":"media"}]}]}`
	want := `<h2>T</h2><ul><li><p><a href="https://x?a=1&amp;b=2">go</a><br/>@Ana</p></li></ul>`
	if got := adfToHTML([]byte(in)); got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}
