package app

import (
	"fmt"
	"net/url"
	"strings"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/syncjob"
)

func (a *App) reportPage(c *ui.Context, jobID int) {
	t := c.Theme()
	j := a.store.Job(jobID)
	if j == nil {
		emptyState(c, "Job not found", fmt.Sprintf("No job with ID %d.", jobID))
		return
	}
	runs := a.store.RunsFor(jobID)
	if len(runs) == 0 {
		page(c, j.Name+" · Report", "", nil, func() { emptyState(c, "No runs yet", "Press Sync Now on the job page.") })
		return
	}
	cur := 0
	want := atoi(a.router.Query("run"))
	for i, r := range runs {
		if r.ID == want {
			cur = i
		}
	}
	st := a.table("report")
	st.sel = cur
	st.list.Key = func(i int) any { return runs[i].ID }

	ui.Row(c).Fill().AlignItems(ui.Stretch).Children(func() {
		list := ui.List(c.Key("runs"), &st.list, len(runs), func(i int) {
			r := runs[i]
			// On the accent-coloured chosen row, status colours and muted text vanish; use the accent's text colour.
			muted, status := t.TextMuted, runStatusColor(t, r.Status())
			if i == st.sel {
				muted, status = t.AccentText.Alpha(0.8), t.AccentText
			}
			ui.Column(c).Padding(8, 12).Gap(2).Children(func() {
				ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
					ui.Textf(c, "Run #%d", r.ID).Bold().Grow(1)
					pill(c, string(r.Status()), status)
				})
				ui.Text(c, r.Started.Format("Jan 2 15:04:05")+" · "+ago(r.Started, a.now())).FontSize(11).TextColor(muted)
			})
		}).Width(260).Shrink(0).Label("Runs")
		if list.Changed() && st.sel >= 0 && st.sel < len(runs) {
			a.router.Replace(fmt.Sprintf("/jobs/%d/report?run=%d", jobID, runs[st.sel].ID))
		}
		ui.Box(c).Width(1).Background(t.Border)
		a.runDetail(c, j, runs[cur])
	})
}

func (a *App) runDetail(c *ui.Context, j *syncjob.Job, r syncjob.Run) {
	t := c.Theme()
	ui.Scroll(c).Grow(1).MinWidth(0).Children(func() {
		ui.Column(c).Padding(20, 24).Gap(16).Children(func() {
			ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
				ui.Column(c).Grow(1).Gap(2).Children(func() {
					ui.Textf(c, "%s · Run #%d", j.Name, r.ID).FontSize(18).Bold()
					since := "full backlog"
					if r.Since != "" {
						since = "since " + r.Since
					}
					ui.Text(c, fmt.Sprintf("%s · took %s · %d tickets · %s", r.Started.Format("Mon Jan 2 15:04:05"), fmtDuration(r.Duration), len(r.Tickets), since)).
						FontSize(12).TextColor(t.TextMuted)
				})
				pill(c, string(r.Status()), runStatusColor(t, r.Status()))
			})
			if r.Error != "" {
				ui.Text(c, r.Error).TextColor(t.Danger).Selectable().Padding(10, 12).Radius(8).Background(t.Danger.Alpha(0.1))
			}
			ui.Grid(c).Columns(4).Gap(12).Children(func() {
				for _, o := range syncjob.Outcomes {
					stat(c, string(o), fmt.Sprint(r.Count(o)), outcomeColor(t, o))
				}
			})
			ui.Text(c, "Tickets").Bold()
			ui.Column(c).Gap(6).Children(func() {
				for i, tk := range r.Tickets {
					a.ticket(c, fmt.Sprintf("%d/%d", r.ID, i), j, tk)
				}
			})
		})
	})
}

func (a *App) ticket(c *ui.Context, key string, j *syncjob.Job, tk syncjob.Ticket) {
	t := c.Theme()
	open := a.openFlag(key)
	ui.Column(c.Key(key)).Radius(8).Border(1, t.Border).Clip().Children(func() {
		p := ui.CollapsibleBase(c, open)
		p.Trigger.Row().Gap(8).Padding(8, 12).AlignItems(ui.Center).Label(tk.Key + " " + tk.Summary)
		if p.Trigger.Hovered() {
			p.Trigger.Background(t.SurfaceHover)
		}
		p.Trigger.Children(func() {
			chevron := iconChevron
			if *open {
				chevron = iconChevronDown
			}
			ui.Icon(c, chevron).Size(14, 14).TextColor(t.TextMuted)
			ui.Text(c, tk.Key).Bold().Font("monospace").FontSize(12).Shrink(0)
			ui.Text(c, tk.Summary).SingleLine().Grow(1).MinWidth(0)
			if tk.ADOID != 0 {
				ui.Text(c, fmt.Sprintf("ADO #%d", tk.ADOID)).FontSize(12).TextColor(t.TextMuted).Shrink(0)
			}
			pill(c, string(tk.Outcome), outcomeColor(t, tk.Outcome))
		})
		p.Panel(func() {
			ui.Column(c).Padding(4, 12, 12, 34).Gap(10).Children(func() {
				a.ticketLinks(c, j, tk)
				if tk.Message != "" {
					ui.Text(c, strings.TrimSpace(tk.WorkItemType+" · "+tk.Message)).FontSize(12).TextColor(t.TextMuted).Selectable()
				}
				if tk.Error != "" {
					ui.Text(c, firstLine(tk.Error)).TextColor(t.Danger).Selectable().MaxLines(3)
				}
				a.syncedSummary(c, tk)
				a.callList(c, key, tk.Calls)
			})
		})
	})
}

// syncedSummary is what reached ADO: fields with their values, then side effects.
func (a *App) syncedSummary(c *ui.Context, tk syncjob.Ticket) {
	t := c.Theme()
	fields, notes := synced(tk.Calls)
	if len(fields) == 0 && len(notes) == 0 {
		if tk.Outcome != syncjob.Failed {
			ui.Text(c, "Nothing was written to ADO.").FontSize(12).TextColor(t.TextMuted)
		}
		return
	}
	ui.Grid(c).ColumnTracks(ui.FitContent(), ui.Fr(1)).GapX(16).GapY(4).Children(func() {
		for _, f := range fields {
			ui.Text(c, f.name).FontSize(12).TextColor(t.TextMuted).SingleLine()
			ui.Text(c, f.value).FontSize(12).SingleLine().Selectable()
		}
	})
	if len(notes) > 0 {
		ui.Text(c, strings.Join(notes, " · ")).FontSize(12).TextColor(t.TextMuted)
	}
}

// callList is a collapsed "N ADO calls" disclosure; each call is one line, its bodies behind Details.
func (a *App) callList(c *ui.Context, key string, calls []syncjob.APICall) {
	t := c.Theme()
	if len(calls) == 0 {
		return
	}
	ui.Collapsible(c.Key("calls"), plural(len(calls), "ADO call"), a.openFlag(key+"/calls"), func() {
		ui.Column(c).Gap(4).Padding(4, 0, 0, 0).Children(func() {
			for i, call := range calls {
				color := t.Success
				if call.Status >= 400 || call.Error != "" {
					color = t.Danger
				}
				ui.Row(c.Key(fmt.Sprint("call", i))).Gap(8).AlignItems(ui.Center).Children(func() {
					pill(c, call.Method, t.Accent)
					ui.Text(c, shortURL(call.URL)).Font("monospace").FontSize(11).SingleLine().Grow(1).MinWidth(0)
					meta := fmtDuration(call.Duration)
					if call.Retries > 0 {
						meta += fmt.Sprintf(" · %d retries", call.Retries)
					}
					ui.Text(c, meta).FontSize(11).TextColor(t.TextMuted).Shrink(0)
					pill(c, fmt.Sprint(call.Status), color)
				})
				if call.Request == "" && call.Response == "" && call.Error == "" {
					continue
				}
				ui.Collapsible(c.Key(fmt.Sprint("details", i)), "Details", a.openFlag(fmt.Sprintf("%s/call%d", key, i)), func() {
					ui.Column(c).Gap(4).Padding(0, 0, 6, 0).Children(func() {
						if call.Error != "" {
							ui.Text(c, call.Error).FontSize(11).TextColor(t.Danger).Selectable()
						}
						if call.Request != "" {
							ui.Text(c, "Sent").FontSize(11).TextColor(t.TextMuted)
							ui.Scroll(c).MaxHeight(160).Children(func() { mono(c, call.Request) })
						}
						if call.Response != "" {
							ui.Text(c, "Response").FontSize(11).TextColor(t.TextMuted)
							ui.Scroll(c).MaxHeight(160).Children(func() { mono(c, call.Response) })
						}
					})
				}).FontSize(11)
			}
		})
	}).FontSize(12)
}

// openFlag is persistent open/closed state for a disclosure, closed by default.
func (a *App) openFlag(key string) *bool {
	open, ok := a.opened[key]
	if !ok {
		open = new(bool)
		a.opened[key] = open
	}
	return open
}

func firstLine(s string) string {
	line, _, _ := strings.Cut(s, "\n")
	return line
}

// ticketLinks opens the issue in Jira and the work item in ADO, in the browser.
func (a *App) ticketLinks(c *ui.Context, j *syncjob.Job, tk syncjob.Ticket) {
	jiraURL, adoURL := issueURL(a.store.Settings[setJiraURL], tk.Key), workItemURL(a.store.Settings[setADOOrg], j.ADOProject, tk.ADOID)
	if jiraURL == "" && adoURL == "" {
		return
	}
	ui.Row(c).Gap(16).AlignItems(ui.Center).Children(func() {
		if jiraURL != "" {
			ui.Link(c, "Open "+tk.Key+" in Jira ↗", jiraURL).FontSize(12).Tooltip(jiraURL)
		}
		if adoURL != "" {
			ui.Link(c, fmt.Sprintf("Open ADO #%d ↗", tk.ADOID), adoURL).FontSize(12).Tooltip(adoURL)
		}
	})
}

// issueURL is the Jira browse link for key, or "" without a site URL.
func issueURL(site, key string) string {
	if site == "" || key == "" {
		return ""
	}
	return strings.TrimRight(site, "/") + "/browse/" + url.PathEscape(key)
}

// workItemURL is the ADO web link for a work item, or "" when it has none yet.
func workItemURL(org, project string, id int) string {
	if org == "" || project == "" || id == 0 {
		return ""
	}
	return fmt.Sprintf("https://dev.azure.com/%s/%s/_workitems/edit/%d", url.PathEscape(org), url.PathEscape(project), id)
}
