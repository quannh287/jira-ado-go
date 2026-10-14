package app

import (
	"fmt"
	"slices"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/syncjob"
)

var jobTabs = []string{"Configuration", "Field Mappings", "Filters", "Sync History", "Activity Log", "Settings"}

func (a *App) jobPage(c *ui.Context, id int) {
	t := c.Theme()
	j := a.store.Job(id)
	if j == nil {
		emptyState(c, "Job not found", fmt.Sprintf("No job with ID %d.", id))
		return
	}
	running := a.running[id]
	sub := fmt.Sprintf("%s → %s · %s", j.JiraKey, j.ADOProject, j.Type)
	page(c, j.Name, sub, func() {
		if running {
			ui.Spinner(c).Label("Syncing")
			ui.Text(c, progressText(a.live[id])).FontSize(12).TextColor(t.TextMuted)
		} else {
			pill(c, string(j.Status), jobStatusColor(t, j.Status))
		}
		last, hasRun := a.store.LastRun(id)
		ui.Button(c.Key("edit"), "Edit Job").OnClick(func() { a.openEditor(id, 0) })
		ui.Button(c.Key("report"), "View Report").Disabled(!hasRun && !running).OnClick(func() {
			if running {
				a.router.Push(fmt.Sprintf("/jobs/%d/report?run=%s", id, liveRun)) // watch it as it goes
				return
			}
			a.router.Push(fmt.Sprintf("/jobs/%d/report?run=%d", id, last.ID))
		})
		if j.Status == syncjob.Active {
			ui.Button(c.Key("pause"), "Pause").Disabled(running).OnClick(func() { a.store.SetStatus(id, syncjob.Paused) })
		} else {
			ui.Button(c.Key("resume"), "Resume").OnClick(func() { a.store.SetStatus(id, syncjob.Active) })
		}
		if running {
			ui.Button(c.Key("cancel"), "Cancel").TextColor(t.Danger).Tooltip("Stops after the current issue; the next sync resumes from the last checkpoint").
				OnClick(func() { a.cancelRun(id) })
			return
		}
		ui.Button(c.Key("dryrun"), "Dry Run").Disabled(j.Status != syncjob.Active).
			Tooltip("Reads Jira and ADO, writes nothing: the report shows what a sync would send").OnClick(func() { a.dryRun(id) })
		ui.PrimaryButton(c.Key("syncnow"), "Sync Now").Disabled(j.Status != syncjob.Active).
			Tooltip("Only ACTIVE jobs can sync").OnClick(func() { a.syncNow(id) })
	}, func() {
		ui.Tabs(c.Key("tabs"), &a.jobTab, jobTabs...).Label("Job sections")
		ui.Column(c).Grow(1).MinHeight(0).Children(func() {
			switch a.jobTab {
			case 0:
				a.editBar(c, id, 0, "Name, ADO project and sync type.")
				ui.Scroll(c).Grow(1).Children(func() {
					ui.Form(c, func() {
						kv(c, "Name", j.Name)
						kv(c, "Jira project", j.JiraKey)
						kv(c, "ADO project", j.ADOProject)
						kv(c, "Direction", "Jira → ADO")
						kv(c, "Sync type", string(j.Type))
						kv(c, "Status", string(j.Status))
						kv(c, "Created", j.Created.Format("Jan 2, 2006 15:04"))
					})
				})
			case 1:
				a.mappingsTable(c, j)
			case 2:
				a.filtersTab(c, j)
			case 3:
				a.runsTable(c, "history", a.store.RunsFor(id), false)
			case 4:
				a.activityTab(c, j)
			case 5:
				a.jobSettings(c, j)
			}
		})
	})
}

// openEditor opens the wizard on a job at a step (1 = mappings, 2 = filters).
func (a *App) openEditor(id, step int) {
	a.editDraft(id, step)
	a.router.Push(fmt.Sprintf("/jobs/%d/edit", id))
}

// editBar sits above a read-only tab and opens the editor at its step.
func (a *App) editBar(c *ui.Context, id, step int, hint string) {
	t := c.Theme()
	ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
		ui.Text(c, hint).FontSize(12).TextColor(t.TextMuted).Grow(1)
		ui.Button(c.Key(fmt.Sprint("edit", step)), "Edit…").OnClick(func() { a.openEditor(id, step) })
	})
}

func (a *App) mappingsTable(c *ui.Context, j *syncjob.Job) {
	a.editBar(c, j.ID, 1, "Only mapped ADO fields are written; title, area, iteration and the Jira key always are.")
	cols := []ui.TableColumn{{Title: "Jira field"}, {Title: "ADO field"}}
	ui.Table(c.Key("mappings"), nil, cols, len(j.Mappings), func(row, col int) {
		m := j.Mappings[row]
		ui.Text(c, []string{m.Jira, m.ADO}[col]).SingleLine()
	}).Grow(1).Label("Field mappings")
}

func (a *App) filtersTab(c *ui.Context, j *syncjob.Job) {
	a.editBar(c, j.ID, 2, "Comments, user filter, user mapping, area and iteration.")
	area, it := j.Paths(a.now())
	ui.Scroll(c).Grow(1).Children(func() {
		ui.Form(c, func() { filtersRows(c, j.Filters, area, it) })
	})
}

func (a *App) activityTab(c *ui.Context, j *syncjob.Job) {
	t := c.Theme()
	log := slices.Clone(j.Activity)
	slices.Reverse(log)
	ui.List(c.Key("activity"), nil, len(log), func(i int) {
		ui.Row(c).Gap(12).Padding(6, 4).Children(func() {
			ui.Text(c, log[i].At.Format("Jan 2 15:04:05")).FontSize(12).TextColor(t.TextMuted).Font("monospace").Shrink(0)
			ui.Text(c, log[i].Text)
		})
	}).Grow(1).Label("Activity log")
}

func (a *App) jobSettings(c *ui.Context, j *syncjob.Job) {
	t := c.Theme()
	id, name := j.ID, j.Name
	ui.Column(c).Gap(8).MaxWidth(520).Children(func() {
		ui.Text(c, "Delete job").Bold()
		ui.Text(c, "Deletes the job and its sync history. Work items already in ADO stay.").FontSize(12).TextColor(t.TextMuted)
		ui.Button(c.Key("delete"), "Delete Job…").TextColor(t.Danger).AlignSelf(ui.Start).OnClick(func() { a.confirm = true })
	})
	switch ui.AlertDialog(c, &a.confirm, "Delete "+name+"?", "Its sync history is deleted too. This can't be undone.", "Cancel", "Delete") {
	case 1:
		a.store.DeleteJob(id)
		a.notice = "Deleted " + name
		a.router.Replace("/jobs")
	}
}

var runColumns = []ui.TableColumn{
	{Title: "Run", Width: 60}, {Title: "Job"}, {Title: "Started", Width: 150}, {Title: "Status", Width: 90},
	{Title: "Created", Width: 70, Align: ui.End}, {Title: "Updated", Width: 70, Align: ui.End},
	{Title: "Skipped", Width: 70, Align: ui.End}, {Title: "Failed", Width: 60, Align: ui.End},
	{Title: "Duration", Width: 80, Align: ui.End},
}

// runsTable lists runs; a click opens the run's report. With manage, rows multi-select and show a delete button.
func (a *App) runsTable(c *ui.Context, key string, runs []syncjob.Run, manage bool) {
	t := c.Theme()
	st := a.table(key)
	st.list.Key = func(i int) any { return runs[i].ID }
	cols := runColumns
	if manage {
		st.list.Selection = &a.logSel
		cols = append(slices.Clone(runColumns), ui.TableColumn{Title: "", ID: "actions", Width: 80, Fixed: true})
	}
	tbl := ui.Table(c.Key(key), &st.list, cols, len(runs), func(row, col int) {
		r := runs[row]
		switch col {
		case 0:
			ui.Textf(c, "#%d", r.ID)
		case 1:
			name := fmt.Sprintf("Job %d", r.JobID)
			if j := a.store.Job(r.JobID); j != nil {
				name = j.Name
			}
			ui.Text(c, name).SingleLine()
		case 2:
			ui.Text(c, r.Started.Format("Jan 2 15:04:05")).SingleLine()
		case 3:
			pill(c, string(r.Status()), runStatusColor(t, r.Status()))
		case 4, 5, 6, 7:
			o := syncjob.Outcomes[col-4]
			ui.Textf(c, "%d", r.Count(o)).TextColor(outcomeColor(t, o))
		case 8:
			ui.Text(c, fmtDuration(r.Duration)).TextColor(t.TextMuted)
		case 9:
			id := r.ID
			ui.Button(c.Key(fmt.Sprint("del", id)), "Delete").OnClick(func() {
				a.store.DeleteRuns(id)
				a.logSel.Remove(id)
			})
		}
	}).Grow(1).Label("Sync runs").Children(func() {
		if len(runs) == 0 {
			emptyState(c, "No runs yet", "Press Sync Now on an ACTIVE job.")
		}
	})
	open := tbl.Submitted()
	if !manage {
		open = open || tbl.Changed()
	}
	if open && st.sel >= 0 && st.sel < len(runs) {
		r := runs[st.sel]
		st.sel = -1
		a.router.Push(fmt.Sprintf("/jobs/%d/report?run=%d", r.JobID, r.ID))
	}
}
