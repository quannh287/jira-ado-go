package app

import (
	"fmt"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/syncjob"
)

func (a *App) dashboard(c *ui.Context) {
	t := c.Theme()
	now := a.now()
	active, today, ok := 0, 0, 0
	for _, j := range a.store.Jobs {
		if j.Status == syncjob.Active {
			active++
		}
	}
	for _, r := range a.store.Runs {
		if now.Sub(r.Started).Hours() < 24 {
			today++
			if r.Status() == syncjob.Success {
				ok++
			}
		}
	}
	rate := "—"
	if today > 0 {
		rate = fmt.Sprintf("%d%%", ok*100/today)
	}
	page(c, "Dashboard", "Jira → ADO sync jobs at a glance", nil, func() {
		ui.Grid(c).Columns(4).Gap(12).Children(func() {
			stat(c, "Total Jobs", fmt.Sprint(len(a.store.Jobs)), t.Text)
			stat(c, "Active", fmt.Sprint(active), t.Success)
			stat(c, "Runs (24h)", fmt.Sprint(today), t.Text)
			stat(c, "Success Rate (24h)", rate, t.Accent)
		})
		a.jobsTable(c, "dashboard")
	})
}

func (a *App) jobsPage(c *ui.Context) {
	page(c, "Sync Jobs", fmt.Sprintf("%d jobs", len(a.store.Jobs)), nil, func() { a.jobsTable(c, "jobs") })
}

var jobColumns = []ui.TableColumn{
	{Title: "Name"}, {Title: "Jira", Width: 80}, {Title: "ADO Project", Width: 140},
	{Title: "Type", Width: 90}, {Title: "Status", Width: 90}, {Title: "Last Run", Width: 150},
}

func (a *App) jobsTable(c *ui.Context, key string) {
	t := c.Theme()
	st := a.table(key)
	jobs := a.store.Jobs
	st.list.Key = func(i int) any { return jobs[i].ID }
	st.list.Label = func(i int) string { return jobs[i].Name }
	tbl := ui.Table(c.Key(key), &st.list, jobColumns, len(jobs), func(row, col int) {
		j := jobs[row]
		switch col {
		case 0:
			ui.Text(c, j.Name).SingleLine()
		case 1:
			ui.Text(c, j.JiraKey).SingleLine()
		case 2:
			ui.Text(c, j.ADOProject).SingleLine()
		case 3:
			ui.Text(c, string(j.Type)).SingleLine()
		case 4:
			if a.running[j.ID] {
				pill(c, "SYNCING", t.Accent)
			} else {
				pill(c, string(j.Status), jobStatusColor(t, j.Status))
			}
		case 5:
			if r, ok := a.store.LastRun(j.ID); ok {
				ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
					pill(c, string(r.Status()), runStatusColor(t, r.Status()))
					ui.Text(c, ago(r.Started, a.now())).FontSize(12).TextColor(t.TextMuted).SingleLine()
				})
			} else {
				ui.Text(c, "Never").TextColor(t.TextMuted)
			}
		}
	}).Grow(1).Label("Sync jobs").Children(func() {
		if len(jobs) == 0 {
			emptyHint(c, iconSync, "No sync jobs yet", [2]string{"⌘N", "New Sync Job"}, [2]string{"⌘K", "Search"})
		}
	})
	if tbl.Changed() && st.sel >= 0 && st.sel < len(jobs) {
		id := jobs[st.sel].ID
		st.sel = -1
		a.jobTab = 0
		a.router.Push(fmt.Sprintf("/jobs/%d", id))
	}
}
