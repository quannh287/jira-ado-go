package app

import (
	"fmt"
	"net/url"
	"slices"
	"strings"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/syncjob"
)

// liveRun is the ?run= value of the run in flight.
const liveRun = "live"

func (a *App) reportPage(c *ui.Context, jobID int) {
	t := c.Theme()
	j := a.store.Job(jobID)
	if j == nil {
		emptyState(c, "Job not found", fmt.Sprintf("No job with ID %d.", jobID))
		return
	}
	type entry struct {
		run  syncjob.Run
		live *syncjob.Progress
	}
	var entries []entry
	if p, ok := a.live[jobID]; ok {
		entries = append(entries, entry{p.Run, &p})
	}
	for _, r := range a.store.RunsFor(jobID) {
		entries = append(entries, entry{run: r})
	}
	if len(entries) == 0 {
		page(c, j.Name+" · Report", "", nil, func() { emptyState(c, "No runs yet", "Press Sync Now on the job page.") })
		return
	}
	cur := 0 // the live run when there is one, else the newest
	q := a.router.Query("run")
	for i, e := range entries {
		if (q == liveRun && e.live != nil) || (e.live == nil && fmt.Sprint(e.run.ID) == q) {
			cur = i
		}
	}
	st := a.table("report")
	st.sel = cur
	st.list.Key = func(i int) any {
		if entries[i].live != nil {
			return liveRun
		}
		return entries[i].run.ID
	}

	ui.Row(c).Fill().AlignItems(ui.Stretch).Children(func() {
		list := ui.List(c.Key("runs"), &st.list, len(entries), func(i int) {
			e := entries[i]
			r := e.run
			// On the accent-coloured chosen row, status colours and muted text vanish; use the accent's text colour.
			muted, status := t.TextMuted, runStatusColor(t, r.Status())
			if i == st.sel {
				muted, status = t.AccentText.Alpha(0.8), t.AccentText
			}
			ui.Column(c).Padding(8, 12).Gap(2).Children(func() {
				ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
					if e.live != nil {
						ui.Text(c, "Live").Bold().Grow(1)
						ui.Spinner(c).Label("Syncing").TextColor(muted)
						return
					}
					ui.Textf(c, "Run #%d", r.ID).Bold().Grow(1)
					if r.Kind != "" {
						pill(c, kindLabel(r.Kind), muted)
					}
					pill(c, string(r.Status()), status)
				})
				sub := r.Started.Format("Jan 2 15:04:05") + " · " + ago(r.Started, a.now())
				if e.live != nil {
					sub = progressText(*e.live)
				}
				ui.Text(c, sub).FontSize(11).TextColor(muted)
			})
		}).Width(260).Shrink(0).Label("Runs")
		if list.Changed() && st.sel >= 0 && st.sel < len(entries) {
			run := fmt.Sprint(entries[st.sel].run.ID)
			if entries[st.sel].live != nil {
				run = liveRun
			}
			a.router.Replace(fmt.Sprintf("/jobs/%d/report?run=%s", jobID, run))
		}
		ui.Box(c).Width(1).Background(t.Border)
		a.runDetail(c, j, entries[cur].run, entries[cur].live)
	})
}

// progressText is "12 of 71 issues" once Jira answered, "Searching Jira…" before.
func progressText(p syncjob.Progress) string {
	if p.Total == 0 {
		return "Searching Jira…"
	}
	return fmt.Sprintf("%d of %d issues", p.Done, p.Total)
}

// runDetail shows a saved run, or with p the run in flight, which redraws as its snapshots arrive.
func (a *App) runDetail(c *ui.Context, j *syncjob.Job, r syncjob.Run, p *syncjob.Progress) {
	t := c.Theme()
	ui.Scroll(c).Grow(1).MinWidth(0).Children(func() {
		ui.Column(c).Padding(20, 24).Gap(16).Children(func() {
			ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
				ui.Column(c).Grow(1).Gap(2).Children(func() {
					since := "full backlog"
					if r.Since != "" {
						since = "since " + r.Since
					}
					if p != nil {
						ui.Textf(c, "%s · Syncing", j.Name).FontSize(18).Bold()
						ui.Text(c, fmt.Sprintf("started %s · %s · %s", r.Started.Format("15:04:05"), progressText(*p), since)).FontSize(12).TextColor(t.TextMuted)
						return
					}
					ui.Textf(c, "%s · Run #%d", j.Name, r.ID).FontSize(18).Bold()
					if r.Kind != "" {
						ui.Text(c, kindLabel(r.Kind)).FontSize(12).Bold().TextColor(t.Accent)
					}
					ui.Text(c, fmt.Sprintf("%s · took %s · %d tickets · %s", r.Started.Format("Mon Jan 2 15:04:05"), fmtDuration(r.Duration), len(r.Tickets), since)).
						FontSize(12).TextColor(t.TextMuted)
				})
				switch {
				case p != nil:
					ui.Button(c.Key("cancelrun"), "Cancel").TextColor(t.Danger).OnClick(func() { a.cancelRun(j.ID) })
					ui.Spinner(c).Label("Syncing")
				default:
					if n := len(r.FailedKeys()); n > 0 && r.Kind != syncjob.KindDryRun && j.Status == syncjob.Active && !a.running[j.ID] {
						ui.Button(c.Key("retry"), fmt.Sprintf("Retry %d Failed", n)).
							Tooltip("Runs just these tickets again; the cursor isn't moved").OnClick(func() { a.retryFailed(r) })
					}
					pill(c, string(r.Status()), runStatusColor(t, r.Status()))
				}
			})
			if p != nil {
				frac := -1.0 // indeterminate until Jira says how many issues there are
				if p.Total > 0 {
					frac = float64(p.Done) / float64(p.Total)
				}
				ui.Progress(c, frac).Label("Sync progress")
			}
			if r.Kind == syncjob.KindDryRun {
				ui.Text(c, "Dry run: nothing was written to ADO. Calls marked \"not sent\" are what a sync would send.").FontSize(12).
					TextColor(t.Accent).Padding(8, 12).Radius(8).Background(t.Accent.Alpha(0.1))
			}
			if r.Error != "" {
				ui.Text(c, r.Error).TextColor(t.Danger).Selectable().Padding(10, 12).Radius(8).Background(t.Danger.Alpha(0.1))
			}
			ui.Grid(c).Columns(4).Gap(12).Children(func() {
				for _, o := range syncjob.Outcomes {
					label := string(o)
					if r.Kind == syncjob.KindDryRun && (o == syncjob.Created || o == syncjob.Updated) {
						label = "would be " + label
					}
					stat(c, label, fmt.Sprint(r.Count(o)), outcomeColor(t, o))
				}
			})
			ui.Text(c, "Tickets").Bold()
			ui.Column(c).Gap(6).Children(func() {
				for _, g := range groupTickets(r.Tickets) {
					a.ticketGroup(c, r, j, g)
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
					ui.Text(c, strings.Join(slices.DeleteFunc([]string{tk.WorkItemType, tk.Message}, func(s string) bool { return s == "" }), " · ")).
						FontSize(12).TextColor(t.TextMuted).Selectable()
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
					if call.Status == 0 && call.Error == "" { // held back by a dry run
						pill(c, "not sent", t.TextMuted)
					} else {
						pill(c, fmt.Sprint(call.Status), color)
					}
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

func kindLabel(kind string) string {
	switch kind {
	case syncjob.KindDryRun:
		return "dry run"
	case syncjob.KindRetry:
		return "retry"
	}
	return kind
}

// ticketGroup is a top-level ticket (or a parent that isn't in the run) with its sub-tasks.
type ticketGroup struct {
	parent    int    // index into the run's tickets, -1 when the parent wasn't synced in this run
	parentKey string // set when parent is -1
	children  []int
}

// groupTickets nests sub-tasks under their parent, in the order tickets first appear.
func groupTickets(tickets []syncjob.Ticket) []ticketGroup {
	byKey := map[string]int{}
	for i, t := range tickets {
		byKey[t.Key] = i
	}
	var groups []ticketGroup
	at := map[string]int{} // parent key → index in groups
	group := func(key string, parent int) *ticketGroup {
		if g, ok := at[key]; ok {
			return &groups[g]
		}
		at[key] = len(groups)
		groups = append(groups, ticketGroup{parent: parent, parentKey: key})
		return &groups[len(groups)-1]
	}
	for i, t := range tickets {
		if p, ok := byKey[t.ParentKey]; ok && t.ParentKey != "" && p != i {
			g := group(t.ParentKey, p)
			g.children = append(g.children, i)
			continue
		}
		if t.ParentKey != "" { // parent not synced in this run: a header still gathers its sub-tasks
			g := group(t.ParentKey, -1)
			g.children = append(g.children, i)
			continue
		}
		g := group(t.Key, i)
		g.parent = i // a sub-task listed before its parent created the group with -1
	}
	return groups
}

func (a *App) ticketGroup(c *ui.Context, r syncjob.Run, j *syncjob.Job, g ticketGroup) {
	t := c.Theme()
	key := func(i int) string { return fmt.Sprintf("%d/%d", r.ID, i) }
	ui.Column(c.Key("group-" + g.parentKey)).Gap(6).Children(func() {
		if g.parent >= 0 {
			a.ticket(c, key(g.parent), j, r.Tickets[g.parent])
		} else {
			ui.Row(c).Gap(8).Padding(6, 12).AlignItems(ui.Center).Children(func() {
				ui.Text(c, g.parentKey).Bold().Font("monospace").FontSize(12)
				ui.Text(c, "parent not in this run").FontSize(12).TextColor(t.TextMuted)
			})
		}
		if len(g.children) == 0 {
			return
		}
		// Open by default: the flag records that the user folded the sub-tasks away.
		folded := a.openFlag(fmt.Sprintf("%d/folded/%s", r.ID, g.parentKey))
		counts := map[syncjob.Outcome]int{}
		for _, i := range g.children {
			counts[r.Tickets[i].Outcome]++
		}
		var parts []string
		for _, o := range syncjob.Outcomes {
			if counts[o] > 0 {
				parts = append(parts, fmt.Sprintf("%d %s", counts[o], o))
			}
		}
		label := plural(len(g.children), "sub-task") + " · " + strings.Join(parts, ", ")
		toggle := ui.ButtonBase(c.Key("fold")).Row().Gap(6).Padding(2, 8).Margin(0, 0, 0, 22).Radius(6).AlignSelf(ui.Start).
			Label(label).TextColor(t.TextMuted)
		if toggle.Hovered() {
			toggle.Background(t.SurfaceHover)
		}
		toggle.Children(func() {
			icon := iconChevronDown
			if *folded {
				icon = iconChevron
			}
			ui.Icon(c, icon).Size(12, 12)
			ui.Text(c, label).FontSize(12)
		}).OnClick(func() { *folded = !*folded })
		if *folded {
			return
		}
		// Sub-tasks hang off a rule on the left, under their parent.
		ui.Column(c).Gap(6).Margin(0, 0, 0, 22).Padding(0, 0, 0, 12).BorderWidth(0, 0, 0, 2).BorderColor(t.Border).Children(func() {
			for _, i := range g.children {
				a.ticket(c, key(i), j, r.Tickets[i])
			}
		})
	})
}
