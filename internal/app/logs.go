package app

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"jira-ado/internal/syncjob"
)

const (
	allJobs     = "All jobs"
	allStatuses = "All statuses"
)

func (a *App) filteredRuns() []syncjob.Run {
	var out []syncjob.Run
	for _, r := range a.store.Runs {
		j := a.store.Job(r.JobID)
		if a.logJob != allJobs && (j == nil || j.Name != a.logJob) {
			continue
		}
		if a.logState != allStatuses && string(r.Status()) != a.logState {
			continue
		}
		out = append(out, r)
	}
	return out
}

func (a *App) logsPage(c *ui.Context) {
	runs := a.filteredRuns()
	jobs := []string{allJobs}
	for _, j := range a.store.Jobs {
		jobs = append(jobs, j.Name)
	}
	statuses := []string{allStatuses}
	for _, s := range syncjob.RunStatuses {
		statuses = append(statuses, string(s))
	}
	page(c, "Logs", fmt.Sprintf("%d of %d runs", len(runs), len(a.store.Runs)), func() {
		ui.Select(c.Key("job"), &a.logJob, jobs).Label("Job").Width(180)
		ui.Select(c.Key("status"), &a.logState, statuses).Label("Status").Width(130)
		ui.Button(c.Key("export"), "Export JSON").Disabled(len(runs) == 0).OnClick(func() { a.exportRuns(runs) })
		n := a.logSel.Len()
		label := "Delete Selected"
		if n > 0 {
			label = fmt.Sprintf("Delete %d…", n)
		}
		ui.Button(c.Key("bulk"), label).Disabled(n == 0).TextColor(c.Theme().Danger).
			OnClick(func() { a.confirm = true })
	}, func() {
		a.runsTable(c, "logs", runs, true)
	})
	n := a.logSel.Len()
	switch ui.AlertDialog(c, &a.confirm, fmt.Sprintf("Delete %d runs?", n), "Their reports are deleted too. This can't be undone.", "Cancel", "Delete") {
	case 1:
		a.store.DeleteRuns(slices.Collect(a.logSel.All())...)
		a.logSel.Clear()
		a.notice = fmt.Sprintf("Deleted %d runs", n)
	}
}

func (a *App) exportRuns(runs []syncjob.Run) {
	data, err := json.MarshalIndent(runs, "", "  ")
	if err != nil {
		a.notice = "Export failed: " + err.Error()
		return
	}
	var msg string
	a.Async(func() {
		// Dialog.Save blocks until the user answers, so it must stay off the UI thread.
		path, err := mygo.Dialog.Save(mygo.SaveDialogOptions{
			Title: "Export runs", DefaultPath: "sync-runs.json",
			Filters: []mygo.FileFilter{{Name: "JSON", Extensions: []string{"json"}}},
		})
		switch {
		case err != nil:
			msg = "Export failed: " + err.Error()
		case path == "":
			return
		default:
			if err := os.WriteFile(path, data, 0o644); err != nil {
				msg = "Export failed: " + err.Error()
			} else {
				msg = fmt.Sprintf("Exported %d runs", len(runs))
			}
		}
	}, func() { a.notice = msg })
}
