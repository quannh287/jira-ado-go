package syncjob

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)

func clock() time.Time { return t0 }

func TestRunStatus(t *testing.T) {
	cases := []struct {
		outcomes []Outcome
		want     RunStatus
	}{
		{[]Outcome{Created, Skipped}, Success},
		{[]Outcome{Created, Failed}, Partial},
		{[]Outcome{Failed, Failed}, Partial}, // only the run itself failing is "failed", as in the source
		{nil, Success},
	}
	for _, c := range cases {
		var r Run
		for _, o := range c.outcomes {
			r.Tickets = append(r.Tickets, Ticket{Outcome: o})
		}
		if got := r.Status(); got != c.want {
			t.Errorf("%v: got %s, want %s", c.outcomes, got, c.want)
		}
	}
}

func TestStore(t *testing.T) {
	s := NewStore(clock)
	a := s.AddJob(Job{Name: "a"})
	b := s.AddJob(Job{Name: "b"})
	if s.Job(a).Status != Active {
		t.Fatal("new job not ACTIVE")
	}
	r1 := s.AddRun(Run{JobID: a})
	r2 := s.AddRun(Run{JobID: b})
	r3 := s.AddRun(Run{JobID: a})
	if last, _ := s.LastRun(a); last.ID != r3 {
		t.Fatalf("last run = %d, want %d", last.ID, r3)
	}
	s.SetStatus(a, Paused)
	s.SetStatus(a, Paused) // no duplicate log
	if n := len(s.Job(a).Activity); n != 2 {
		t.Fatalf("activity = %d entries, want 2", n)
	}
	s.DeleteRuns(r1)
	if len(s.RunsFor(a)) != 1 {
		t.Fatal("DeleteRuns kept the run")
	}
	s.DeleteJob(b)
	if s.Job(b) != nil || s.Run(r2) != nil {
		t.Fatal("DeleteJob left the job or its runs")
	}
}

func TestPaths(t *testing.T) {
	j := Job{ADOProject: "kai", Filters: DefaultFilters()}
	if area, it := j.Paths(t0); area != DefaultAreaPath || it != `Tickets\Weekly Sprint\Sprint 82` {
		t.Fatalf("auto paths = %q, %q", area, it)
	}
	j.Filters = Filters{AreaPath: `kai\App`, Iteration: `kai\S1`}
	if area, it := j.Paths(t0); area != `kai\App` || it != `kai\S1` {
		t.Fatalf("fixed paths = %q, %q", area, it)
	}
}

func TestFake(t *testing.T) {
	f := NewFake(0, clock)
	if _, err := f.ValidatePAT(context.Background(), "org", "short"); err == nil {
		t.Fatal("short PAT accepted")
	}
	j := Job{ID: 1, JiraKey: "SE", ADOProject: "kai", Mappings: SmartDefaults(), Filters: DefaultFilters()}
	r := f.Sync(context.Background(), Connection{}, j, RunOptions{})
	if len(r.Tickets) < 3 || r.JobID != 1 {
		t.Fatalf("run = %+v", r)
	}
	for _, tk := range r.Tickets {
		if !strings.HasPrefix(tk.Key, "SE-") {
			t.Fatalf("ticket key %q", tk.Key)
		}
		for _, c := range tk.Calls {
			if !strings.Contains(c.Request, `Sprint 82`) {
				t.Fatalf("iteration not sent: %s", c.Request)
			}
		}
	}
}

func TestSQLiteRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")
	s, err := Open(path, clock)
	if err != nil {
		t.Fatal(err)
	}
	var saveErr error
	s.OnSaveError = func(err error) { saveErr = err }
	Seed(s, NewFake(0, clock), t0)
	keep := s.AddJob(Job{Name: "keep", JiraKey: "K", ADOProject: "p", Type: Webhook, Mappings: SmartDefaults(),
		Filters: Filters{Users: []UserPair{{Jira: "a", ADOEmail: "a@x"}}}})
	s.AddRun(NewFake(0, clock).Sync(context.Background(), Connection{}, *s.Job(keep), RunOptions{}))
	s.SetStatus(keep, Paused)
	s.DeleteJob(1)
	s.DeleteRuns(s.Runs[len(s.Runs)-1].ID)
	if saveErr != nil {
		t.Fatal(saveErr)
	}
	wantJobs, wantRuns := s.Jobs, s.Runs
	s.Close()

	r, err := Open(path, clock)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if len(r.Jobs) != len(wantJobs) || len(r.Runs) != len(wantRuns) {
		t.Fatalf("reopened %d jobs / %d runs, want %d / %d", len(r.Jobs), len(r.Runs), len(wantJobs), len(wantRuns))
	}
	j := r.Job(keep)
	if j == nil || j.Status != Paused || len(j.Mappings) != len(Supported) || j.Filters.Users[0].ADOEmail != "a@x" || len(j.Activity) != 2 {
		t.Fatalf("job not restored: %+v", j)
	}
	got, want := r.Runs[0], wantRuns[0]
	if got.ID != want.ID || len(got.Tickets) != len(want.Tickets) || got.Tickets[0].Key != want.Tickets[0].Key || !got.Started.Equal(want.Started) {
		t.Fatalf("run not restored: %+v vs %+v", got, want)
	}
	if r.RunsFor(1) != nil {
		t.Fatal("cascade left runs of the deleted job")
	}
	// IDs continue after a reopen instead of colliding.
	if id := r.AddJob(Job{Name: "new"}); id <= keep {
		t.Fatalf("new job id %d reuses an old one", id)
	}
}

func TestRunErrorIsFailed(t *testing.T) {
	if (Run{Error: "jira 401"}).Status() != Error {
		t.Fatal("a run that failed outright must be failed")
	}
}

// A database made before migrations existed (user_version 0, v1 tables, data) upgrades in place.
func TestMigrateLegacyDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	s, err := Open(path, clock)
	if err != nil {
		t.Fatal(err)
	}
	id := s.AddJob(Job{Name: "old"})
	ctx := context.Background()
	for _, q := range []string{`DROP TABLE settings`, `DROP TABLE sync_state`, `DROP TABLE comment_mappings`, `PRAGMA user_version = 0`} {
		if _, err := s.db.Execute(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	for _, col := range []string{"tickets DROP COLUMN parent_key", "runs DROP COLUMN kind", "runs DROP COLUMN since", "runs DROP COLUMN error", "tickets DROP COLUMN work_item_type", "tickets DROP COLUMN ado_id", "tickets DROP COLUMN message"} {
		if _, err := s.db.Execute(ctx, "ALTER TABLE "+col); err != nil {
			t.Fatal(err)
		}
	}
	s.Close()

	r, err := Open(path, clock)
	if err != nil {
		t.Fatalf("legacy DB didn't migrate: %v", err)
	}
	defer r.Close()
	if r.Job(id) == nil {
		t.Fatal("job lost in migration")
	}
	if err := r.State().SetCursor(ctx, id, "2026-10-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	r.SetSetting("ado_org", "kai")
	if cur, _ := r.State().Cursor(ctx, id); cur != "2026-10-01T00:00:00Z" {
		t.Fatalf("cursor %q", cur)
	}
}

func TestImport(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "i.db"), clock)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	existing := s.AddJob(Job{Name: "local", JiraKey: "WEB"})
	im := Import{
		Jobs:     []Job{{ID: 1, Name: "SE", JiraKey: "SE", Status: Active}, {ID: 2, Name: "CAT", JiraKey: "CAT", Status: Paused}},
		Runs:     []Run{{JobID: 2, Started: t0, Tickets: []Ticket{{Key: "CAT-1", Outcome: Created, ADOID: 7}}}, {JobID: 1, Started: t0.Add(time.Hour), Error: "killed"}},
		Cursors:  map[int]string{1: "2026-09-09T01:34:14.741Z"},
		Comments: []CommentMapping{{WorkItemID: 7, JiraCommentID: "c1", ADOCommentID: 3, JiraUpdated: "u"}},
		Settings: map[string]string{"ado_org": "ats"},
	}
	if err := s.Import(context.Background(), im); err != nil {
		t.Fatal(err)
	}
	se := s.Jobs[1]
	if se.ID == existing || se.JiraKey != "SE" {
		t.Fatalf("jobs not renumbered after existing ones: %+v", s.Jobs)
	}
	if cur, _ := s.State().Cursor(context.Background(), se.ID); cur != "2026-09-09T01:34:14.741Z" {
		t.Fatalf("cursor not remapped: %q", cur)
	}
	if s.Runs[0].JobID != se.ID || s.Runs[0].Status() != Error {
		t.Fatalf("newest run first, remapped: %+v", s.Runs[0])
	}
	if m, _ := s.State().CommentMappings(context.Background(), 7); m["c1"].ADOCommentID != 3 {
		t.Fatalf("comment mapping %+v", m)
	}
	if err := s.Import(context.Background(), im); err == nil || len(s.Jobs) != 3 {
		t.Fatalf("second import of the same projects must be refused: err=%v jobs=%d", err, len(s.Jobs))
	}
}

func TestUpdateJobPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "u.db")
	s, _ := Open(path, clock)
	id := s.AddJob(Job{Name: "a", JiraKey: "SE", Mappings: SmartDefaults(), Filters: DefaultFilters()})
	j := *s.Job(id)
	j.Name, j.Mappings, j.Filters.SyncComments, j.JiraKey = "b", SmartDefaults()[:2], false, "OTHER"
	s.UpdateJob(j)
	s.Close()
	r, _ := Open(path, clock)
	defer r.Close()
	got := r.Job(id)
	if got.Name != "b" || len(got.Mappings) != 2 || got.Filters.SyncComments || got.JiraKey != "SE" {
		t.Fatalf("after reopen: %+v", got)
	}
}

func TestRulesAndSharedUsersPersist(t *testing.T) {
	path := filepath.Join(t.TempDir(), "r.db")
	s, _ := Open(path, clock)
	if got := s.Rules().State(TypePBI, "In Review"); got != "Verify Test" {
		t.Fatalf("default rules: %q", got)
	}
	r := s.Rules()
	r.States["In Review"] = "Committed"
	r.Types = map[string]string{"Bug": "Bug"}
	s.SetRules(r)
	s.SetSharedUsers([]UserPair{{Jira: "ana@x", ADOEmail: "ana@ado"}})
	s.Close()
	re, _ := Open(path, clock)
	defer re.Close()
	got := re.Rules()
	if got.State(TypePBI, "in review") != "Committed" || got.WorkItemType("bug", false) != "Bug" || got.Priority("High") != "2" {
		t.Fatalf("rules after reopen: %+v", got)
	}
	if u := re.SharedUsers(); len(u) != 1 || u[0].ADOEmail != "ana@ado" {
		t.Fatalf("shared users %+v", u)
	}
	// Migration v3: the run kind survives a reopen.
	id := re.AddJob(Job{Name: "x", JiraKey: "X"})
	re.AddRun(Run{JobID: id, Kind: KindDryRun})
	if re.Runs[0].Kind != KindDryRun {
		t.Fatal("kind not kept in memory")
	}
}
