package app

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/syncjob"
)

type pair struct{ from, to string }

// mappingsForm is the Mappings page's draft; nothing applies until Save.
type mappingsForm struct {
	loaded                                bool
	users                                 []syncjob.UserPair
	types, states, taskStates, priorities []pair
	subtaskType, defaultType              string
}

func (a *App) loadMappings() {
	r := a.store.Rules()
	a.mappings = mappingsForm{loaded: true, users: slices.Clone(a.store.SharedUsers()),
		types: pairs(r.Types), states: pairs(r.States), taskStates: pairs(r.TaskStates), priorities: pairs(r.Priorities),
		subtaskType: r.SubtaskType, defaultType: r.DefaultType}
}

func pairs(m map[string]string) []pair {
	out := make([]pair, 0, len(m))
	for k, v := range m {
		out = append(out, pair{k, v})
	}
	slices.SortFunc(out, func(a, b pair) int { return strings.Compare(a.from, b.from) })
	return out
}

func toMap(ps []pair) map[string]string {
	m := map[string]string{}
	for _, p := range ps {
		if k := strings.TrimSpace(p.from); k != "" {
			m[k] = strings.TrimSpace(p.to)
		}
	}
	return m
}

// mappingsError says why the draft can't be saved, or "".
func (f *mappingsForm) mappingsError() string {
	for _, u := range f.users {
		if strings.TrimSpace(u.Jira) == "" || !strings.Contains(u.ADOEmail, "@") {
			return "Each shared user needs a Jira user and an ADO email."
		}
	}
	for _, t := range []struct {
		name string
		rows []pair
	}{{"Work item types", f.types}, {"Backlog item states", f.states}, {"Task states", f.taskStates}, {"Priorities", f.priorities}} {
		seen := map[string]bool{}
		for _, p := range t.rows {
			k := strings.ToLower(strings.TrimSpace(p.from))
			switch {
			case k == "" || strings.TrimSpace(p.to) == "":
				return t.name + ": fill in both sides of every row."
			case seen[k]:
				return fmt.Sprintf("%s: %q is mapped twice.", t.name, p.from)
			}
			seen[k] = true
		}
	}
	for _, p := range f.priorities {
		if !slices.Contains([]string{"1", "2", "3", "4"}, strings.TrimSpace(p.to)) {
			return "Priorities: ADO priority is 1, 2, 3 or 4."
		}
	}
	if strings.TrimSpace(f.subtaskType) == "" || strings.TrimSpace(f.defaultType) == "" {
		return "Work item types: set the type for sub-tasks and for everything else."
	}
	return ""
}

func (a *App) saveMappings() {
	f := &a.mappings
	a.store.SetSharedUsers(f.users)
	a.store.SetRules(syncjob.Rules{Types: toMap(f.types), States: toMap(f.states), TaskStates: toMap(f.taskStates),
		Priorities: toMap(f.priorities), SubtaskType: strings.TrimSpace(f.subtaskType), DefaultType: strings.TrimSpace(f.defaultType)})
	a.loadMappings() // show what the next sync will use, defaults filled in
	a.notice = "Mappings saved; the next sync uses them"
}

// catalogState is what Jira and ADO offer as mapping values, loaded once per visit to the page.
type catalogState struct {
	cat     syncjob.Catalog
	loading bool
	tried   bool
	err     string
}

// loadCatalog asks the engine for the choices of every project the jobs use.
func (a *App) loadCatalog() {
	cs := &a.catalog
	var jiraProjects, adoProjects []string
	for _, j := range a.store.Jobs {
		jiraProjects, adoProjects = append(jiraProjects, j.JiraKey), append(adoProjects, j.ADOProject)
	}
	jiraProjects, adoProjects = syncjob.Union(jiraProjects), syncjob.Union(adoProjects)
	cs.tried, cs.loading, cs.err = true, true, ""
	if len(jiraProjects) == 0 {
		cs.loading, cs.err = false, "Create a sync job first; the lists come from its Jira and ADO projects."
		return
	}
	conn := a.connection()
	var cat syncjob.Catalog
	var err error
	a.Async(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		cat, err = a.engine.Catalog(ctx, conn, jiraProjects, adoProjects)
	}, func() {
		cs.loading, cs.cat = false, cat
		if err != nil {
			cs.err = err.Error()
		}
	})
}

func (a *App) mappingsPage(c *ui.Context) {
	t := c.Theme()
	if !a.mappings.loaded {
		a.loadMappings()
	}
	if !a.catalog.tried { // once per launch; Refresh Options reloads
		a.loadCatalog()
	}
	f := &a.mappings
	cat := a.catalog.cat
	err := f.mappingsError()
	page(c, "Mappings", "Shared by every job", func() {
		if err != "" {
			ui.Text(c, err).FontSize(12).TextColor(t.Danger).SingleLine()
		}
		ui.Button(c.Key("refreshcat"), "Refresh Options").Disabled(a.catalog.loading).
			Tooltip("Reload Jira statuses, issue types and priorities, and ADO types and states").OnClick(a.loadCatalog)
		ui.Button(c.Key("reset"), "Reset Rules to Defaults").Tooltip("The source app's rules; shared users stay").OnClick(func() {
			d := syncjob.DefaultRules()
			f.types, f.states, f.taskStates, f.priorities = pairs(d.Types), pairs(d.States), pairs(d.TaskStates), pairs(d.Priorities)
			f.subtaskType, f.defaultType = d.SubtaskType, d.DefaultType
		})
		ui.Button(c.Key("revert"), "Revert").OnClick(a.loadMappings)
		ui.PrimaryButton(c.Key("savemap"), "Save").Disabled(err != "").OnClick(a.saveMappings)
	}, func() {
		ui.Scroll(c).Grow(1).MinHeight(0).Children(func() {
			ui.Column(c).MaxWidth(760).Gap(24).Padding(0, 0, 24, 0).Children(func() {
				switch cs := a.catalog; {
				case cs.loading:
					ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
						ui.Spinner(c).Label("Loading options")
						ui.Text(c, "Loading statuses and types from Jira and ADO…").FontSize(12).TextColor(t.TextMuted)
					})
				case cs.err != "":
					ui.Text(c, "Some lists couldn't load, so those fields take typed values: "+cs.err).FontSize(12).TextColor(t.Warning).Selectable()
				}
				a.sharedUsers(c)
				// States of the backlog types this page maps to: the default, the overrides, and Scrum's usual two.
				backlog := []string{f.defaultType, syncjob.TypePBI, "Bug"}
				for _, p := range f.types {
					if !syncjob.IsTask(p.to) {
						backlog = append(backlog, p.to)
					}
				}
				mapSection(c, "Work item types", "Which ADO work item type a Jira issue becomes.", func() {
					ui.Form(c, func() {
						ui.Field(c, "Sub-tasks", func() { choice(c, "subtask", &f.subtaskType, cat.ADOTypes, syncjob.TypeTask) })
						ui.Field(c, "Everything else", func() { choice(c, "default", &f.defaultType, cat.ADOTypes, syncjob.TypePBI) })
					})
					pairRows(c, "types", &f.types, cat.JiraTypes, cat.ADOTypes, "Jira issue type (e.g. Bug)", "ADO type (e.g. Bug)", "Add Type Override")
				})
				mapSection(c, "States: backlog items", "Jira status → ADO state for PBIs, Bugs and other non-Task types. Unmapped statuses use the type's first state (New).", func() {
					pairRows(c, "states", &f.states, cat.JiraStatuses, cat.StatesFor(backlog...), "Jira status", "ADO state", "Add State")
				})
				mapSection(c, "States: tasks", "Jira status → ADO state for Tasks. Unmapped statuses use To Do.", func() {
					pairRows(c, "taskstates", &f.taskStates, cat.JiraStatuses, cat.StatesFor(syncjob.TypeTask, f.subtaskType), "Jira status", "ADO state", "Add State")
				})
				mapSection(c, "Priorities", "Jira priority → ADO priority 1 (highest) to 4. Unmapped priorities use 4.", func() {
					pairRows(c, "priorities", &f.priorities, cat.JiraPriorities, adoPriorities, "Jira priority", "1–4", "Add Priority")
				})
			})
		})
	})
}

func (a *App) sharedUsers(c *ui.Context) {
	t := c.Theme()
	f := &a.mappings
	mapSection(c, "Users", "Jira user (email or display name) → ADO email, for Assigned To and Created By. A job's own user mapping wins over this one.", func() {
		for i := range f.users {
			ui.Row(c.Key(fmt.Sprint("user", i))).Gap(8).AlignItems(ui.Center).Children(func() {
				ui.TextInput(c.Key("jira"), &f.users[i].Jira).Placeholder("Jira email or name").Label("Jira user").Grow(1).Basis(0)
				ui.Text(c, "→").TextColor(t.TextMuted)
				ui.TextInput(c.Key("email"), &f.users[i].ADOEmail).Placeholder("name@company.com").Label("ADO email").Grow(1).Basis(0)
				ui.Button(c.Key("remove"), "Remove").OnClick(func() { f.users = slices.Delete(f.users, i, i+1) })
			})
		}
		ui.Row(c).Gap(8).Children(func() {
			ui.Button(c.Key("adduser"), "Add User").OnClick(func() { f.users = append(f.users, syncjob.UserPair{}) })
			ui.Button(c.Key("importusers"), "Import from Jobs").Tooltip("Adds every job's user mapping that isn't here yet").OnClick(a.importJobUsers)
		})
	})
}

// importJobUsers copies the jobs' user mappings into the shared table, skipping Jira users already there.
func (a *App) importJobUsers() {
	f := &a.mappings
	have := map[string]bool{}
	for _, u := range f.users {
		have[strings.ToLower(strings.TrimSpace(u.Jira))] = true
	}
	added := 0
	for _, j := range a.store.Jobs {
		for _, u := range j.Filters.Users {
			if k := strings.ToLower(strings.TrimSpace(u.Jira)); k != "" && !have[k] {
				have[k] = true
				f.users = append(f.users, u)
				added++
			}
		}
	}
	a.notice = fmt.Sprintf("Imported %d users; Save to keep them", added)
}

func mapSection(c *ui.Context, title, desc string, body func()) {
	t := c.Theme()
	ui.Column(c).Gap(10).Children(func() {
		ui.Column(c).Gap(2).Children(func() {
			ui.Text(c, title).FontSize(15).Bold()
			ui.Text(c, desc).FontSize(12).TextColor(t.TextMuted)
		})
		body()
	})
}

var adoPriorities = []string{"1", "2", "3", "4"}

// pairRows edits a from → to table in place; each side is a drop-down when its options are known.
func pairRows(c *ui.Context, key string, rows *[]pair, fromOpts, toOpts []string, fromHint, toHint, addLabel string) {
	t := c.Theme()
	for i := range *rows {
		ui.Row(c.Key(fmt.Sprint(key, i))).Gap(8).AlignItems(ui.Center).Children(func() {
			choice(c, "from", &(*rows)[i].from, fromOpts, fromHint).Grow(1).Basis(0)
			ui.Text(c, "→").TextColor(t.TextMuted)
			choice(c, "to", &(*rows)[i].to, toOpts, toHint).Grow(1).Basis(0)
			ui.Button(c.Key("remove"), "Remove").OnClick(func() { *rows = slices.Delete(*rows, i, i+1) })
		})
	}
	ui.Button(c.Key(key+"add"), addLabel).AlignSelf(ui.Start).OnClick(func() {
		*rows = append(*rows, pair{first(fromOpts), first(toOpts)}) // a select needs a value from its list
	})
}

// choice is a select over options, or a text input while the options are unknown.
// A saved value missing from the list stays selectable, so loading the lists never changes a rule.
func choice(c *ui.Context, key string, value *string, options []string, hint string) ui.Element {
	if len(options) == 0 {
		return ui.TextInput(c.Key(key), value).Placeholder(hint).Label(hint)
	}
	if *value != "" && !slices.Contains(options, *value) { // exact: the select shows a value only when it is one of its options
		options = append(slices.Clone(options), *value)
	}
	return ui.Select(c.Key(key), value, options).Label(hint)
}

func first(opts []string) string {
	if len(opts) == 0 {
		return ""
	}
	return opts[0]
}
