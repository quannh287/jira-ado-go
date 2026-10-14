package app

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/syncjob"
)

// memSecrets stands in for the keychain.
type memSecrets struct{ v string }

func (m *memSecrets) Get() (string, error) { return m.v, nil }
func (m *memSecrets) Set(v string) error   { m.v = v; return nil }
func (m *memSecrets) Delete() error        { m.v = ""; return nil }

func newTestApp() (*App, *ui.Tester) {
	return newTestAppWith(&memSecrets{})
}

func newTestAppWith(s Secrets) (*App, *ui.Tester) {
	now := func() time.Time { return time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC) }
	a := New(syncjob.NewFake(0, now), syncjob.NewStore(now), Keys{PAT: s, Jira: &memSecrets{}}, now)
	a.login.org = "kai"
	a.router.Transition = ui.TransitionNone // a sliding page would move under the Tester's clicks
	return a, ui.NewTester(a.View, 1180, 760)
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestMainFlow(t *testing.T) {
	a, tt := newTestApp()

	// Login rejects a bad PAT, accepts a good one.
	tt.Type("bad")
	must(t, tt.Click("Sign In"))
	if a.pat != "" || !tt.HasText(syncjob.ErrInvalidPAT.Error()) {
		t.Fatalf("bad PAT: pat=%q texts=%q", a.pat, tt.Texts())
	}
	a.login.pat = "abcdefghijklmnopqrstuvwxyz0123456789"
	tt.Frame()
	must(t, tt.Click("Sign In"))
	if a.pat == "" || !tt.HasText("No sync jobs yet") {
		t.Fatalf("login failed: texts=%q", tt.Texts())
	}

	// Create wizard: 4 steps, mapping required, lands back on the dashboard.
	must(t, tt.Click("New Sync Job  ⌘N"))
	a.draft.job.Name, a.draft.job.JiraKey, a.draft.job.ADOProject = "Mobile", "se", "kai-mobile"
	tt.Frame()
	must(t, tt.Click("Next"))
	if a.draft.step != 1 || a.draft.stepError(1) == "" {
		t.Fatalf("step %d, mapping error %q", a.draft.step, a.draft.stepError(1))
	}
	must(t, tt.Click("Smart Defaults (11)"))
	if len(a.draft.job.Mappings) != len(syncjob.Supported) {
		t.Fatalf("smart defaults gave %d pairs", len(a.draft.job.Mappings))
	}
	must(t, tt.Click("Next"))
	must(t, tt.Click("Next"))
	must(t, tt.Click("Create Job"))
	if len(a.store.Jobs) != 1 || a.router.Path() != "/" || a.store.Jobs[0].JiraKey != "SE" {
		t.Fatalf("jobs=%v path=%s", a.store.Jobs, a.router.Path())
	}

	// Job page: Sync Now only while ACTIVE, then the run opens in the report.
	a.router.Push("/jobs/1")
	tt.Frame()
	must(t, tt.Click("Pause"))
	must(t, tt.Click("Sync Now"))
	if len(a.store.Runs) != 0 {
		t.Fatal("paused job synced")
	}
	must(t, tt.Click("Resume"))
	must(t, tt.Click("Sync Now"))
	if len(a.store.Runs) != 1 {
		t.Fatalf("runs = %d after Sync Now", len(a.store.Runs))
	}
	must(t, tt.Click("View Report"))
	if a.router.Path() != "/jobs/1/report" || !tt.HasText("Run #1") {
		t.Fatalf("report: path=%s texts=%q", a.router.Path(), tt.Texts())
	}

	// Logs: bulk delete through the confirmation.
	a.router.Push("/logs")
	a.logSel.Add(1)
	tt.Frame()
	must(t, tt.Click("Delete 1…"))
	tt.Key(0, ui.KeyEnter) // the alert's default button; rows have "Delete" buttons too
	if len(a.store.Runs) != 0 {
		t.Fatalf("runs = %d after bulk delete", len(a.store.Runs))
	}
}

func TestStepErrors(t *testing.T) {
	d := newDraft()
	if d.stepError(0) == "" {
		t.Fatal("empty basic step accepted")
	}
	d.job.Mappings = []syncjob.FieldPair{{Jira: "summary", ADO: "System.Title"}, {Jira: "status", ADO: "System.Title"}}
	if d.stepError(1) == "" {
		t.Fatal("duplicate ADO field accepted")
	}
	d.job.Filters.Users = []syncjob.UserPair{{Jira: "x", ADOEmail: "no-at"}}
	if d.stepError(2) == "" {
		t.Fatal("invalid email accepted")
	}
	d.job.Filters.Users[0].ADOEmail = "x@kai.example"
	d.job.Filters.AutoPaths = false
	if d.stepError(2) == "" {
		t.Fatal("empty fixed paths accepted")
	}
}

func TestSidebarToggle(t *testing.T) {
	a, tt := newTestApp()
	a.pat = "abcdefghijklmnopqrstuvwxyz0123456789"
	tt.Frame()
	must(t, tt.Click("Hide Sidebar"))
	if !a.collapsed {
		t.Fatal("sidebar did not collapse")
	}
	must(t, tt.Click("Show Sidebar"))
	tt.Key(ui.Cmd|ui.Ctrl, ui.KeyS)
	if !a.collapsed {
		t.Fatal("⌃⌘S did not toggle the sidebar")
	}
}

func TestRememberPAT(t *testing.T) {
	const pat = "abcdefghijklmnopqrstuvwxyz0123456789"
	secrets := &memSecrets{}
	a, tt := newTestAppWith(secrets)
	a.login.pat = pat
	tt.Frame()
	must(t, tt.Click("Sign In"))
	if secrets.v != pat || !a.remember {
		t.Fatalf("PAT not saved: %q remember=%v", secrets.v, a.remember)
	}

	// A new launch finds the saved PAT and skips login.
	b, _ := newTestAppWith(secrets)
	if b.pat != pat {
		t.Fatal("saved PAT not loaded at launch")
	}

	// Turning Remember off in Settings removes it from the keychain.
	b.router.Push("/settings")
	tb := ui.NewTester(b.View, 1180, 760)
	must(t, tb.Click("Remember PAT"))
	if secrets.v != "" || b.remember {
		t.Fatalf("PAT still saved: %q remember=%v", secrets.v, b.remember)
	}

	// Signing in with Remember unchecked keeps it out of the keychain.
	c, tc := newTestAppWith(secrets)
	c.login.pat, c.login.remember = pat, false
	tc.Frame()
	must(t, tc.Click("Sign In"))
	if secrets.v != "" || c.pat != pat {
		t.Fatalf("session-only sign in: saved=%q pat=%q", secrets.v, c.pat)
	}

	// Sign out forgets it.
	secrets.v = pat
	c.logout()
	if secrets.v != "" {
		t.Fatal("logout left the PAT in the keychain")
	}
}

func TestThemeToggle(t *testing.T) {
	a, tt := newTestApp()
	a.pat = "abcdefghijklmnopqrstuvwxyz0123456789"
	tt.Frame()
	must(t, tt.Click("Dark Theme")) // the Tester starts light
	if a.store.Settings[setTheme] != themeDark {
		t.Fatalf("theme = %q after Dark Theme", a.store.Settings[setTheme])
	}
	tt.Frame()
	must(t, tt.Click("Light Theme"))
	if a.store.Settings[setTheme] != themeLight {
		t.Fatalf("theme = %q after Light Theme", a.store.Settings[setTheme])
	}
}

func TestEditJob(t *testing.T) {
	a, tt := newTestApp()
	a.pat = "abcdefghijklmnopqrstuvwxyz0123456789"
	a.router.Transition = ui.TransitionNone
	id := a.store.AddJob(syncjob.Job{Name: "SE", JiraKey: "SE", ADOProject: "Tickets", Mappings: syncjob.SmartDefaults(), Filters: syncjob.DefaultFilters()})
	a.router.Push(fmt.Sprintf("/jobs/%d", id))
	a.jobTab = 2 // Filters
	tt.Frame()
	must(t, tt.Click("Edit…"))
	if a.router.Path() != fmt.Sprintf("/jobs/%d/edit", id) || a.draft.step != 2 || a.draft.editing != id {
		t.Fatalf("path %s step %d editing %d", a.router.Path(), a.draft.step, a.draft.editing)
	}
	a.draft.job.Filters.SyncComments = false
	a.draft.job.Mappings = a.draft.job.Mappings[:3]
	if a.store.Job(id).Filters.SyncComments == false {
		t.Fatal("the wizard edited the stored job before Save")
	}
	tt.Frame()
	must(t, tt.Click("Field Mapping")) // stepper jumps back
	if a.draft.step != 1 {
		t.Fatalf("step %d after clicking Field Mapping", a.draft.step)
	}
	must(t, tt.Click("Save Changes"))
	j := a.store.Job(id)
	if j.Filters.SyncComments || len(j.Mappings) != 3 || j.JiraKey != "SE" || a.router.Path() != fmt.Sprintf("/jobs/%d", id) {
		t.Fatalf("not saved: %+v path %s", j, a.router.Path())
	}
	if last := j.Activity[len(j.Activity)-1].Text; last != "Job settings changed" {
		t.Fatalf("activity %q", last)
	}
}

// progressEngine reports one snapshot mid-run.
type progressEngine struct{ syncjob.Fake }

func (e *progressEngine) Sync(ctx context.Context, conn syncjob.Connection, j syncjob.Job, opts syncjob.RunOptions) syncjob.Run {
	run := syncjob.Run{JobID: j.ID, Started: time.Now(), Tickets: []syncjob.Ticket{{Key: "CAT-1", Summary: "first", Outcome: syncjob.Updated}}}
	opts.OnProgress(syncjob.Progress{Run: run.Snapshot(), Done: 1, Total: 3})
	return run
}

func TestLiveReport(t *testing.T) {
	a, tt := newTestApp()
	a.pat = "abcdefghijklmnopqrstuvwxyz0123456789"
	a.router.Transition = ui.TransitionNone
	a.engine = &progressEngine{}
	var work, done func()
	a.Async = func(w, d func()) { work, done = w, d } // the test decides when the worker runs and finishes
	id := a.store.AddJob(syncjob.Job{Name: "CAT", JiraKey: "CAT", ADOProject: "Tickets", Filters: syncjob.DefaultFilters()})
	a.router.Push(fmt.Sprintf("/jobs/%d", id))
	tt.Frame()
	must(t, tt.Click("Sync Now"))
	work() // snapshot posted: 1 of 3
	tt.Frame()
	if !tt.HasText("1 of 3 issues") {
		t.Fatalf("job page progress: %q", tt.Texts())
	}
	must(t, tt.Click("View Report"))
	if a.router.Query("run") != liveRun || !tt.HasText("Live") || !tt.HasText("CAT-1") || !tt.HasText("CAT · Syncing") {
		t.Fatalf("live report: query %q texts %q", a.router.Query("run"), tt.Texts())
	}
	done()
	tt.Frame()
	if q := a.router.Query("run"); q != fmt.Sprint(a.store.Runs[0].ID) || tt.HasText("Live") {
		t.Fatalf("after the run: query %q texts %q", q, tt.Texts())
	}
}

// recordingEngine keeps the options and job of each run and returns a run with one failed ticket.
type recordingEngine struct {
	syncjob.Fake
	opts []syncjob.RunOptions
	jobs []syncjob.Job
	ctx  context.Context
}

func (e *recordingEngine) Sync(ctx context.Context, conn syncjob.Connection, j syncjob.Job, opts syncjob.RunOptions) syncjob.Run {
	e.opts, e.jobs, e.ctx = append(e.opts, opts), append(e.jobs, j), ctx
	run := syncjob.Run{JobID: j.ID, Started: time.Now(), Tickets: []syncjob.Ticket{{Key: "CAT-7", Outcome: syncjob.Failed, Error: "TF401320"}}}
	if opts.DryRun {
		run.Kind = syncjob.KindDryRun
	} else if len(opts.Keys) > 0 {
		run.Kind = syncjob.KindRetry
	}
	return run
}

func TestDryRunCancelAndRetry(t *testing.T) {
	a, tt := newTestApp()
	a.pat = "abcdefghijklmnopqrstuvwxyz0123456789"
	a.router.Transition = ui.TransitionNone
	eng := &recordingEngine{}
	a.engine = eng
	id := a.store.AddJob(syncjob.Job{Name: "CAT", JiraKey: "CAT", ADOProject: "Tickets", Filters: syncjob.DefaultFilters(),
		Mappings: syncjob.SmartDefaults()})
	a.store.SetSharedUsers([]syncjob.UserPair{{Jira: "ana@x", ADOEmail: "ana@ado"}})
	a.router.Push(fmt.Sprintf("/jobs/%d", id))
	tt.Frame()

	must(t, tt.Click("Dry Run"))
	if !eng.opts[0].DryRun || a.store.Runs[0].Kind != syncjob.KindDryRun {
		t.Fatalf("dry run opts %+v run %+v", eng.opts[0], a.store.Runs[0])
	}
	// The shared user mapping reaches the engine after the job's own.
	if u := eng.jobs[0].Filters.Users; len(u) != 1 || u[0].ADOEmail != "ana@ado" {
		t.Fatalf("users sent to the engine %+v", u)
	}
	if _, ok := a.store.LastRun(id); ok {
		t.Fatal("a dry run must not count as the job's last run")
	}

	// Retry is offered on a real run with failures, and reruns only those keys.
	must(t, tt.Click("Sync Now"))
	a.router.Push(fmt.Sprintf("/jobs/%d/report?run=%d", id, a.store.Runs[0].ID))
	tt.Frame()
	must(t, tt.Click("Retry 1 Failed"))
	if keys := eng.opts[2].Keys; len(keys) != 1 || keys[0] != "CAT-7" || a.store.Runs[0].Kind != syncjob.KindRetry {
		t.Fatalf("retry opts %+v", eng.opts[2])
	}

	// Cancel cancels the run's context.
	var work, done func()
	a.Async = func(w, d func()) { work, done = w, d }
	a.router.Push(fmt.Sprintf("/jobs/%d", id))
	tt.Frame()
	must(t, tt.Click("Sync Now"))
	tt.Frame()
	must(t, tt.Click("Cancel"))
	work()
	if eng.ctx.Err() == nil {
		t.Fatal("Cancel didn't cancel the run's context")
	}
	done()
}

func TestMappingsPage(t *testing.T) {
	a, tt := newTestApp()
	a.pat = "abcdefghijklmnopqrstuvwxyz0123456789"
	a.router.Transition = ui.TransitionNone
	a.store.AddJob(syncjob.Job{Name: "CAT", JiraKey: "CAT", Filters: syncjob.Filters{Users: []syncjob.UserPair{{Jira: "bo@x", ADOEmail: "bo@ado"}}}})
	a.router.Push("/mappings")
	tt.Frame()
	if !tt.HasText("Mappings") || len(a.mappings.states) != 4 {
		t.Fatalf("defaults not loaded: %+v", a.mappings)
	}
	must(t, tt.Click("Import from Jobs"))
	a.mappings.types = append(a.mappings.types, pair{"Bug", "Bug"})
	a.mappings.priorities = append(a.mappings.priorities, pair{"Blocker", "9"})
	tt.Frame()
	if a.mappings.mappingsError() == "" {
		t.Fatal("priority 9 accepted")
	}
	a.mappings.priorities[len(a.mappings.priorities)-1].to = "1"
	tt.Frame()
	must(t, tt.Click("Save"))
	r := a.store.Rules()
	if r.WorkItemType("bug", false) != "Bug" || r.Priority("blocker") != "1" || len(a.store.SharedUsers()) != 1 {
		t.Fatalf("saved rules %+v users %+v", r, a.store.SharedUsers())
	}
	if a.connection().Rules.Priority("Blocker") != "1" {
		t.Fatal("the next sync wouldn't get the saved rules")
	}
}
