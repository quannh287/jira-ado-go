package app

import (
	"cmp"
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/syncjob"
)

var steps = []string{"Basic", "Field Mapping", "Filters", "Review"}

type draft struct {
	step    int
	job     syncjob.Job
	editing int // the job being edited, 0 while creating one
	// check is the last "Check in ADO" result for this draft.
	checking bool
	checked  []string
	checkErr string
	checkOK  bool
}

// editDraft loads a job into the wizard at step.
func (a *App) editDraft(id, step int) {
	j := a.store.Job(id)
	if j == nil {
		return
	}
	job := *j
	job.Mappings = slices.Clone(j.Mappings) // the wizard edits a copy until Save
	job.Filters.Users = slices.Clone(j.Filters.Users)
	a.draft = draft{step: step, job: job, editing: id}
}

// editPage is the wizard on an existing job; Back/forward can land here with another job's draft.
func (a *App) editPage(c *ui.Context, id int) {
	if a.store.Job(id) == nil {
		emptyState(c, "Job not found", fmt.Sprintf("No job with ID %d.", id))
		return
	}
	if a.draft.editing != id {
		a.editDraft(id, 0)
	}
	a.createPage(c)
}

func newDraft() draft {
	return draft{job: syncjob.Job{Type: syncjob.Manual, Filters: syncjob.DefaultFilters()}}
}

// stepError says why the user can't leave step i, or "" when they can.
func (d *draft) stepError(i int) string {
	j := d.job
	switch i {
	case 0:
		switch {
		case strings.TrimSpace(j.Name) == "":
			return "Enter a job name."
		case strings.TrimSpace(j.JiraKey) == "":
			return "Enter the Jira project key."
		case strings.TrimSpace(j.ADOProject) == "":
			return "Enter the ADO project ID."
		}
	case 1:
		if len(j.Mappings) == 0 {
			return "Map at least one field."
		}
		seen := map[string]bool{}
		for _, m := range j.Mappings {
			if !syncjob.IsSupported(m) {
				return m.Label() + " isn't a pair the sync can write."
			}
			if seen[m.ADO] {
				return m.ADO + " is mapped twice."
			}
			seen[m.ADO] = true
		}
	case 2:
		for _, u := range j.Filters.Users {
			if strings.TrimSpace(u.Jira) == "" || !strings.Contains(u.ADOEmail, "@") {
				return "Each user mapping needs a Jira user and an ADO email."
			}
		}
		f := j.Filters
		switch {
		case strings.TrimSpace(f.AreaPath) == "":
			return "Enter the ADO area path."
		case !f.AutoPaths && strings.TrimSpace(f.Iteration) == "":
			return "Enter a fixed iteration path, or derive it from the weekly sprint."
		case f.AutoPaths && strings.TrimSpace(f.SprintRoot) == "":
			return "Enter the sprint root path."
		case f.AutoPaths && !validDate(f.AnchorDate):
			return "Enter the anchor date as yyyy-mm-dd."
		}
	}
	return ""
}

func (a *App) createPage(c *ui.Context) {
	t := c.Theme()
	d := &a.draft
	title, sub := "New Sync Job", "Jira → ADO"
	if d.editing != 0 {
		title, sub = "Edit "+d.job.Name, d.job.JiraKey+" → "+d.job.ADOProject
	}
	page(c, title, sub, nil, func() {
		a.stepper(c)
		ui.Scroll(c).Grow(1).MinHeight(0).Children(func() {
			ui.Column(c).MaxWidth(720).Gap(16).Padding(4, 0).Children(func() {
				switch d.step {
				case 0:
					a.stepBasic(c)
				case 1:
					a.stepMapping(c)
				case 2:
					a.stepFilters(c)
				case 3:
					a.stepReview(c)
				}
			})
		})
		ui.Divider(c)
		err := d.stepError(d.step)
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			ui.Button(c.Key("cancel"), "Cancel").OnClick(func() {
				back := "/"
				if d.editing != 0 {
					back = fmt.Sprintf("/jobs/%d", d.editing)
				}
				a.draft = newDraft()
				a.router.Push(back)
			})
			ui.Spacer(c)
			if err != "" {
				ui.Text(c, err).FontSize(12).TextColor(t.TextMuted).SingleLine()
			}
			ui.Button(c.Key("back"), "Back").Disabled(d.step == 0).OnClick(func() { d.step-- })
			if d.step < len(steps)-1 {
				ui.PrimaryButton(c.Key("next"), "Next").Disabled(err != "").OnClick(func() { d.step++ })
			}
			switch {
			case d.editing != 0:
				// Editing can save from any step once every step is valid.
				ui.PrimaryButton(c.Key("save"), "Save Changes").Disabled(d.firstInvalid() < len(steps)).OnClick(a.saveJob)
			case d.step == len(steps)-1:
				ui.PrimaryButton(c.Key("create"), "Create Job").OnClick(a.createJob)
			}
		})
	})
}

func (a *App) createJob() {
	j := a.draft.job
	j.Name, j.JiraKey, j.ADOProject = strings.TrimSpace(j.Name), strings.ToUpper(strings.TrimSpace(j.JiraKey)), strings.TrimSpace(j.ADOProject)
	a.store.AddJob(j)
	a.draft = newDraft()
	a.notice = "Created " + j.Name
	a.router.Push("/")
}

// firstInvalid is the first step that can't be left, or len(steps).
func (d *draft) firstInvalid() int {
	for i := range steps {
		if d.stepError(i) != "" {
			return i
		}
	}
	return len(steps)
}

func (a *App) saveJob() {
	j := a.draft.job
	j.Name, j.ADOProject = strings.TrimSpace(j.Name), strings.TrimSpace(j.ADOProject)
	a.store.UpdateJob(j)
	a.draft = newDraft()
	a.notice = "Saved " + j.Name
	a.router.Push(fmt.Sprintf("/jobs/%d", j.ID))
}

func (a *App) stepper(c *ui.Context) {
	t := c.Theme()
	reachable := a.draft.firstInvalid() // steps up to the first invalid one can be clicked
	ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
		for i, s := range steps {
			if i > 0 {
				ui.Box(c).Height(1).Width(24).Background(t.Border)
			}
			color, label := t.TextMuted, fmt.Sprint(i+1)
			switch {
			case i == a.draft.step:
				color = t.Accent
			case i < a.draft.step:
				color, label = t.Success, "✓"
			}
			step := ui.ButtonBase(c.Key("step"+s)).Row().Gap(6).AlignItems(ui.Center).Padding(2, 4).Radius(6).Label(s).Disabled(i > reachable)
			if step.Hovered() && i <= reachable {
				step.Background(t.SurfaceHover)
			}
			step.Children(func() {
				ui.Box(c).Size(20, 20).Radius(10).Center().Background(color.Alpha(0.15)).Children(func() {
					ui.Text(c, label).FontSize(11).Bold().TextColor(color)
				})
				name := ui.Text(c, s).FontSize(13).TextColor(color)
				if i == a.draft.step {
					name.Bold()
				}
			}).OnClick(func() { a.draft.step = i })
		}
	})
}

func (a *App) stepBasic(c *ui.Context) {
	j := &a.draft.job
	ui.Form(c, func() {
		ui.Field(c, "Job name", func() { ui.TextInput(c.Key("name"), &j.Name).Placeholder("Mobile bugs → ADO").AutoFocus() })
		ui.Field(c, "Jira project key", func() {
			ui.TextInput(c.Key("jira"), &j.JiraKey).Placeholder("SE").ReadOnly(a.draft.editing != 0)
		}).Description(map[bool]string{true: "Fixed after creation: the sync cursor and ADO links belong to this project."}[a.draft.editing != 0])
		ui.Field(c, "ADO project ID", func() { ui.TextInput(c.Key("ado"), &j.ADOProject).Placeholder("kai-mobile") })
		kv(c, "Direction", "Jira → ADO")
		ui.Field(c, "Sync type", func() {
			ui.RadioGroup(c, func() {
				for _, st := range syncjob.SyncTypes {
					ui.Radio(c, &j.Type, st, string(st))
				}
			}).Row().Gap(16).Label("Sync type")
		}).Description(map[syncjob.SyncType]string{
			syncjob.Manual:    "Runs only when you press Sync Now.",
			syncjob.Scheduler: "Runs on a schedule.",
			syncjob.Webhook:   "Runs when Jira sends an issue event.",
		}[j.Type])
		if j.Type == syncjob.Scheduler {
			ui.Field(c, "Run every", func() {
				every := fmtEvery(j.Filters.Every())
				ui.Select(c.Key("every"), &every, everyLabels).Label("Run every").OnChange(func() {
					if k := slices.Index(everyLabels, every); k >= 0 {
						j.Filters.EveryMinutes = everyMinutes[k]
					}
				})
			}).Description("Counted from the last run, while the app is open (also in the background).")
		}
	})
}

var (
	everyMinutes = []int{15, 30, 60, 180, 360, 720, 1440}
	everyLabels  = []string{"15 minutes", "30 minutes", "1 hour", "3 hours", "6 hours", "12 hours", "24 hours"}
)

// fmtEvery labels an interval as the Run every select does, or in plain minutes when it's not one of its options.
func fmtEvery(d time.Duration) string {
	if k := slices.Index(everyMinutes, int(d.Minutes())); k >= 0 {
		return everyLabels[k]
	}
	return fmt.Sprintf("%d minutes", int(d.Minutes()))
}

// syncTypeLabel is the job's sync type, with the interval for Scheduler jobs.
func syncTypeLabel(j syncjob.Job) string {
	if j.Type == syncjob.Scheduler {
		return "Scheduler · every " + fmtEvery(j.Filters.Every())
	}
	return string(j.Type)
}

func (a *App) stepMapping(c *ui.Context) {
	t := c.Theme()
	j := &a.draft.job
	labels := make([]string, len(syncjob.Supported))
	for i, p := range syncjob.Supported {
		labels[i] = p.Label()
	}
	ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
		ui.Column(c).Grow(1).Children(func() {
			ui.Text(c, fmt.Sprintf("%d field pairs", len(j.Mappings))).Bold()
			ui.Text(c, "Only mapped ADO fields are written; title, area, iteration and the Jira key always are.").FontSize(12).TextColor(t.TextMuted)
		})
		ui.Button(c.Key("defaults"), fmt.Sprintf("Smart Defaults (%d)", len(syncjob.Supported))).Tooltip("Every field the sync can write").OnClick(func() {
			for _, p := range syncjob.SmartDefaults() {
				if !slices.ContainsFunc(j.Mappings, func(m syncjob.FieldPair) bool { return m.ADO == p.ADO }) {
					j.Mappings = append(j.Mappings, p)
				}
			}
		})
		next, ok := a.unmappedPair()
		ui.Button(c.Key("addpair"), "Add Pair").Disabled(!ok).OnClick(func() { j.Mappings = append(j.Mappings, next) })
	})
	if len(j.Mappings) == 0 {
		ui.Text(c, "No fields mapped yet. Start with Smart Defaults or add a pair.").TextColor(t.TextMuted)
	}
	for i := range j.Mappings {
		label := j.Mappings[i].Label()
		ui.Row(c.Key(fmt.Sprint("pair", i))).Gap(8).AlignItems(ui.Center).Children(func() {
			ui.Select(c.Key("pair"), &label, labels).Label("Jira → ADO field").Grow(1).OnChange(func() {
				if k := slices.Index(labels, label); k >= 0 {
					j.Mappings[i] = syncjob.Supported[k]
				}
			})
			ui.Button(c.Key("remove"), "Remove").OnClick(func() { j.Mappings = slices.Delete(j.Mappings, i, i+1) })
		})
	}
}

func (a *App) unmappedPair() (syncjob.FieldPair, bool) {
	for _, p := range syncjob.Supported {
		if !slices.ContainsFunc(a.draft.job.Mappings, func(m syncjob.FieldPair) bool { return m.ADO == p.ADO }) {
			return p, true
		}
	}
	return syncjob.FieldPair{}, false
}

func (a *App) stepFilters(c *ui.Context) {
	t := c.Theme()
	f := &a.draft.job.Filters
	ui.Form(c, func() {
		switchField(c, "Sync comments", "comments", &f.SyncComments, "Copy Jira comments to the ADO discussion; edits patch the same comment.")
		switchField(c, "User filter", "userfilter", &f.UserFilter, "Only sync issues whose assignee is listed below, or, with no list, maps to an ADO email.")
		if f.UserFilter {
			ui.Field(c, "Assignees", func() {
				ui.TextInput(c.Key("assignees"), &f.Assignees).Placeholder("Mapped users")
			}).Description("Jira emails or display names, comma-separated.")
		}
		ui.Field(c, "Area path", func() { ui.TextInput(c.Key("area"), &f.AreaPath).Placeholder(syncjob.DefaultAreaPath) })
		ui.Field(c, "Iteration", func() {
			ui.RadioGroup(c, func() {
				ui.Radio(c, &f.AutoPaths, true, "Follow Jira sprint")
				ui.Radio(c, &f.AutoPaths, false, "Fixed path")
			}).Row().Gap(16).Label("Iteration")
		})
		if f.AutoPaths {
			ui.Field(c, "Sprint root", func() { ui.TextInput(c.Key("root"), &f.SprintRoot).Placeholder(syncjob.DefaultSprintRoot) })
			anchor := float64(f.AnchorSprint)
			ui.Field(c, "Anchor sprint", func() {
				ui.NumberInput(c.Key("anchor"), &anchor, 1, 9999, 1).Width(120).OnChange(func() { f.AnchorSprint = int(anchor) })
			})
			ui.Field(c, "Anchor date", func() { ui.TextInput(c.Key("anchordate"), &f.AnchorDate).Placeholder("2026-06-01").Width(140) }).
				Description("Monday the anchor sprint starts; one ADO sprint per week after it.")
			_, it := a.draft.job.Paths(a.now())
			kv(c, "In active Jira sprint", it)
			kv(c, "Otherwise (backlog)", a.draft.job.BacklogPath())
		} else {
			ui.Field(c, "Iteration path", func() { ui.TextInput(c.Key("iter"), &f.Iteration).Placeholder(`Tickets\Sprint 42`) })
		}
	})

	a.checkRow(c)
	ui.Divider(c)
	ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
		ui.Column(c).Grow(1).Children(func() {
			ui.Text(c, "User mapping").Bold()
			ui.Text(c, "Jira user (email or display name) → ADO email, for Assigned To and Created By.").FontSize(12).TextColor(t.TextMuted)
		})
		ui.Button(c.Key("adduser"), "Add User").OnClick(func() { f.Users = append(f.Users, syncjob.UserPair{}) })
	})
	for i := range f.Users {
		ui.Row(c.Key(fmt.Sprint("user", i))).Gap(8).AlignItems(ui.Center).Children(func() {
			ui.TextInput(c.Key("jira"), &f.Users[i].Jira).Placeholder("Jira email or name").Label("Jira user").Grow(1).Basis(0)
			ui.Text(c, "→").TextColor(t.TextMuted)
			ui.TextInput(c.Key("email"), &f.Users[i].ADOEmail).Placeholder("name@company.com").Label("ADO email").Grow(1).Basis(0)
			ui.Button(c.Key("remove"), "Remove").OnClick(func() { f.Users = slices.Delete(f.Users, i, i+1) })
		})
	}
}

func validDate(s string) bool {
	_, err := time.Parse("2006-01-02", strings.TrimSpace(s))
	return err == nil
}

func (a *App) stepReview(c *ui.Context) {
	j := a.draft.job
	jobDetails(c, j, a.now())
	ui.Text(c, "The job starts ACTIVE. Run it from its page with Sync Now.").FontSize(12).TextColor(c.Theme().TextMuted)
}

// jobDetails is the read-only summary shared by Review and the job page.
func jobDetails(c *ui.Context, j syncjob.Job, now time.Time) {
	f := j.Filters
	area, it := j.Paths(now)
	ui.Form(c, func() {
		ui.Fieldset(c, "Basic", func() {
			kv(c, "Name", j.Name)
			kv(c, "Jira project", j.JiraKey)
			kv(c, "ADO project", j.ADOProject)
			kv(c, "Direction", "Jira → ADO")
			kv(c, "Sync type", syncTypeLabel(j))
		})
		ui.Fieldset(c, "Field mapping", func() {
			for _, m := range j.Mappings {
				kv(c, m.Jira, m.ADO)
			}
		})
		ui.Fieldset(c, "Filters", func() {
			filtersRows(c, f, area, it)
		})
	})
}

func yesNo(b bool) string {
	if b {
		return "Yes"
	}
	return "No"
}

func orDefault(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}

// filtersRows is the read-only Filters summary shared by Review and the job's Filters tab.
func filtersRows(c *ui.Context, f syncjob.Filters, area, iteration string) {
	kv(c, "Sync comments", yesNo(f.SyncComments))
	scope := "Everyone"
	if f.UserFilter {
		scope = orDefault(f.Assignees, "Assignees mapped to an ADO email")
	}
	kv(c, "Assignees", scope)
	kv(c, "Area path", area)
	if f.AutoPaths {
		kv(c, "In active Jira sprint", fmt.Sprintf("%s (weekly, Sprint %d = %s)", iteration, f.AnchorSprint, f.AnchorDate))
		kv(c, "Otherwise (backlog)", cmp.Or(f.SprintRoot, syncjob.DefaultSprintRoot))
	} else {
		kv(c, "Iteration", iteration)
	}
	if len(f.Users) == 0 {
		kv(c, "User mapping", "None")
	}
	for _, u := range f.Users {
		kv(c, u.Jira, u.ADOEmail)
	}
}

// checkRow runs the engine's preflight on the draft: the paths and the Sprint field a sync needs.
func (a *App) checkRow(c *ui.Context) {
	t := c.Theme()
	d := &a.draft
	ui.Column(c).Gap(6).Children(func() {
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			ui.Button(c.Key("check"), "Check in ADO").Disabled(d.checking).
				Tooltip("Looks up the area and iteration paths in ADO and the Sprint field in Jira").OnClick(a.checkDraft)
			switch {
			case d.checking:
				ui.Spinner(c).Label("Checking")
			case d.checkErr != "":
				ui.Text(c, d.checkErr).FontSize(12).TextColor(t.Danger)
			case d.checkOK:
				ui.Text(c, "✓ Paths exist in ADO; ready to sync").FontSize(12).TextColor(t.Success)
			}
		})
		for _, p := range d.checked {
			ui.Text(c, "• "+p).FontSize(12).TextColor(t.Danger)
		}
	})
}

func (a *App) checkDraft() {
	d := &a.draft
	conn, job := a.connection(), a.effectiveJob(d.job)
	d.checking, d.checked, d.checkErr, d.checkOK = true, nil, "", false
	var problems []string
	var err error
	a.Async(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		problems, err = a.engine.Check(ctx, conn, job)
	}, func() {
		d.checking = false
		switch {
		case err != nil:
			d.checkErr = err.Error()
		case len(problems) > 0:
			d.checked = problems
		default:
			d.checkOK = true
		}
	})
}
