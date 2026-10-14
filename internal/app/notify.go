package app

import (
	"fmt"
	"strings"

	"jira-ado/internal/syncjob"
)

// Notifier shows desktop notifications; main wires MyGo's, tests record them.
type Notifier interface {
	Notify(id, title, subtitle, body string)
	Supported() bool
}

// Notification modes, stored under setNotify.
const (
	notifyAll      = "all"
	notifyFailures = "failures"
	notifyOff      = "off"
)

var notifyModes = []string{notifyAll, notifyFailures, notifyOff}

func (a *App) notifyMode() string {
	if m := a.store.Settings[setNotify]; m != "" {
		return m
	}
	return notifyAll
}

// notifyRun tells the user a run finished, unless the mode says otherwise; a click opens its report.
func (a *App) notifyRun(job syncjob.Job, r syncjob.Run) {
	mode := a.notifyMode()
	failed := r.Status() != syncjob.Success
	if a.Notifier == nil || mode == notifyOff || (mode == notifyFailures && !failed) {
		return
	}
	what := map[string]string{syncjob.KindDryRun: "Dry run", syncjob.KindRetry: "Retry"}[r.Kind]
	if what == "" {
		what = "Sync"
	}
	subtitle, body := what+" finished", fmtRunCounts(r)
	switch {
	case r.Error != "":
		subtitle, body = what+" failed", r.Error
	case r.Count(syncjob.Failed) > 0:
		subtitle = what + " finished with failures"
		keys := r.FailedKeys()
		more := ""
		if len(keys) > 3 {
			keys, more = keys[:3], fmt.Sprintf(" +%d", len(r.FailedKeys())-3)
		}
		body += "\nFailed: " + strings.Join(keys, ", ") + more
	}
	a.Notifier.Notify(notificationID(job.ID, r.ID), job.Name, subtitle, body)
}

// fmtRunCounts is "1 created · 8 updated · 6 skipped · 0 failed".
func fmtRunCounts(r syncjob.Run) string {
	parts := make([]string, len(syncjob.Outcomes))
	for i, o := range syncjob.Outcomes {
		parts[i] = fmt.Sprintf("%d %s", r.Count(o), o)
	}
	return strings.Join(parts, " · ")
}

// Notification IDs are "run/<job>/<run>", so a click, even one that relaunches the app, knows what to open.
func notificationID(jobID, runID int) string { return fmt.Sprintf("run/%d/%d", jobID, runID) }

// testNotificationID is the Settings test's; its click opens Settings.
const testNotificationID = "test"

// OpenNotification shows what a clicked notification is about, on the UI thread, and returns the page it opened.
// Anything it doesn't recognize, such as a run deleted since, lands on the dashboard rather than nowhere.
func (a *App) OpenNotification(id string) string {
	target := "/"
	var job, run int
	switch {
	case id == testNotificationID:
		target = "/settings"
	case scan(id, &job, &run) && a.store.Job(job) != nil && a.store.Run(run) != nil:
		target = fmt.Sprintf("/jobs/%d/report?run=%d", job, run)
	case job != 0 && a.store.Job(job) != nil:
		target = fmt.Sprintf("/jobs/%d", job) // the run is gone: its job
	}
	a.router.Push(target)
	return target
}

func scan(id string, job, run *int) bool {
	_, err := fmt.Sscanf(id, "run/%d/%d", job, run)
	return err == nil
}
