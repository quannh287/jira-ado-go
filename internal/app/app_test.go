package app

import (
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
