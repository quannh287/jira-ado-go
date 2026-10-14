package app

import (
	"strings"
	"testing"

	"jira-ado/internal/syncjob"
)

type sentNotification struct{ id, title, subtitle, body string }

type recordingNotifier struct{ sent []sentNotification }

func (r *recordingNotifier) Notify(id, title, subtitle, body string) {
	r.sent = append(r.sent, sentNotification{id, title, subtitle, body})
}
func (r *recordingNotifier) Supported() bool { return true }

func TestRunNotifications(t *testing.T) {
	a, tt := newTestApp()
	a.pat = "abcdefghijklmnopqrstuvwxyz0123456789"
	n := &recordingNotifier{}
	a.Notifier = n
	eng := &recordingEngine{} // every run has one failed ticket, CAT-7
	a.engine = eng
	id := a.store.AddJob(syncjob.Job{Name: "CAT", JiraKey: "CAT", ADOProject: "Tickets", Filters: syncjob.DefaultFilters()})

	a.syncNow(id)
	if len(n.sent) != 1 {
		t.Fatalf("sent %+v", n.sent)
	}
	got := n.sent[0]
	if got.title != "CAT" || got.subtitle != "Sync finished with failures" || !strings.Contains(got.body, "1 failed") || !strings.Contains(got.body, "Failed: CAT-7") {
		t.Fatalf("notification %+v", got)
	}

	// Clicking it opens that run's report.
	a.OpenNotification(got.id)
	tt.Frame()
	if a.router.Path() != "/jobs/1/report" || a.router.Query("run") != "1" {
		t.Fatalf("opened %s?run=%s", a.router.Path(), a.router.Query("run"))
	}

	// Failures only still reports this run; Off reports nothing.
	a.store.SetSetting(setNotify, notifyFailures)
	a.dryRun(id)
	a.store.SetSetting(setNotify, notifyOff)
	a.syncNow(id)
	if len(n.sent) != 2 || n.sent[1].subtitle != "Dry run finished with failures" {
		t.Fatalf("modes: %+v", n.sent)
	}
	if got := a.OpenNotification("run/99/1"); got != "/" {
		t.Fatalf("deleted job opened %q, want the dashboard", got)
	}
	if got := a.OpenNotification("run/1/999"); got != "/jobs/1" {
		t.Fatalf("deleted run opened %q, want its job", got)
	}
	if got := a.OpenNotification(testNotificationID); got != "/settings" {
		t.Fatalf("test notification opened %q", got)
	}
	if got := a.OpenNotification("garbage"); got != "/" {
		t.Fatalf("garbage opened %q", got)
	}
}

func TestFailuresOnlySkipsCleanRuns(t *testing.T) {
	a, _ := newTestApp()
	n := &recordingNotifier{}
	a.Notifier = n
	a.store.SetSetting(setNotify, notifyFailures)
	a.notifyRun(syncjob.Job{ID: 1, Name: "CAT"}, syncjob.Run{ID: 2, Tickets: []syncjob.Ticket{{Outcome: syncjob.Updated}}})
	if len(n.sent) != 0 {
		t.Fatalf("clean run notified in failures-only mode: %+v", n.sent)
	}
	a.notifyRun(syncjob.Job{ID: 1, Name: "CAT"}, syncjob.Run{ID: 3, Error: "Preflight: Area path missing"})
	if len(n.sent) != 1 || n.sent[0].subtitle != "Sync failed" || n.sent[0].body != "Preflight: Area path missing" {
		t.Fatalf("failed run: %+v", n.sent)
	}
}
