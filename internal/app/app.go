// Package app is the native UI of the Jira→ADO sync tool.
package app

import (
	"cmp"
	"context"
	"time"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/appicon"
	"jira-ado/internal/syncjob"
)

const (
	TitleBarHeight = 52
	sidebarWidth   = 228
	sidebarInset   = 8 // gap between the floating sidebar and the window edges
	// A first run imports the whole backlog; checkpoints make a run stopped by this resumable.
	syncTimeout = time.Hour
)

// Secrets keeps one secret outside the app's files (the OS keychain in production).
type Secrets interface {
	Get() (string, error)
	Set(string) error
	Delete() error
}

// Keys are the app's secrets: the ADO PAT and the Jira API token.
type Keys struct{ PAT, Jira Secrets }

// Settings keys in the store.
const (
	setADOOrg       = "ado_org"
	setADOUser      = "ado_user"
	setJiraURL      = "jira_url"
	setJiraEmail    = "jira_email"
	setJQLExtra     = "jql_extra"
	setJiraKeyField = "jira_key_field"
	setTheme        = "theme"
	setAppIcon      = appicon.SettingKey
)

type App struct {
	// Async runs work off the UI thread, then done on it; the default runs both inline, for tests.
	Async func(work, done func())
	// LogPath is the diagnostic log file, shown in Settings so a problem can be traced.
	LogPath string

	engine  syncjob.Engine
	store   *syncjob.Store
	secrets Keys
	// jiraToken is read from the keychain at launch; Settings writes both.
	jiraToken string
	now       func() time.Time
	router    *ui.Router

	pat      string // ponytail: a saved PAT is trusted at launch; sign out when the real engine gets a 401
	remember bool   // the PAT is kept in the keychain across launches
	login    loginForm
	notice   string // toast to show on the next frame, set from async callbacks

	settings  settingsForm
	palette   bool
	collapsed bool
	query     string
	draft     draft
	running   map[int]bool
	jobTab    int
	opened    map[string]*bool
	confirm   bool
	tables    map[string]*table
	logJob    string
	logState  string
	logSel    ui.Selection[int]
}

// table is the per-table widget state a ui.Table needs across frames.
type table struct {
	list ui.ListState
	sel  int
}

func New(engine syncjob.Engine, store *syncjob.Store, secrets Keys, now func() time.Time) *App {
	a := &App{
		Async:    func(work, done func()) { work(); done() },
		engine:   engine,
		store:    store,
		now:      now,
		router:   ui.NewRouter("/"),
		draft:    newDraft(),
		running:  map[int]bool{},
		opened:   map[string]*bool{},
		tables:   map[string]*table{},
		logJob:   allJobs,
		logState: allStatuses,
		secrets:  secrets,
		login:    loginForm{remember: true},
	}
	store.OnSaveError = func(err error) { a.notice = "Couldn't save: " + err.Error() }
	if pat, err := secrets.PAT.Get(); err != nil {
		a.login.err = "Couldn't read the saved PAT from Keychain: " + err.Error()
	} else {
		a.pat, a.remember = pat, pat != ""
	}
	if tok, err := secrets.Jira.Get(); err != nil {
		a.notice = "Couldn't read the Jira token from Keychain: " + err.Error()
	} else {
		a.jiraToken = tok
	}
	a.login.org = store.Settings[setADOOrg]
	a.settings = settingsForm{
		jiraURL: store.Settings[setJiraURL], jiraEmail: store.Settings[setJiraEmail], jqlExtra: store.Settings[setJQLExtra],
		keyField: cmp.Or(store.Settings[setJiraKeyField], syncjob.DefaultJiraKeyField), jiraToken: a.jiraToken,
	}
	return a
}

func (a *App) table(key string) *table {
	t, ok := a.tables[key]
	if !ok {
		t = &table{sel: -1}
		t.list.Selected = &t.sel
		a.tables[key] = t
	}
	return t
}

func (a *App) View(c *ui.Context) {
	ct := a.contentTheme(c)
	st := sidebarTheme(ct)
	c.SetTheme(&ct)
	if a.notice != "" {
		c.Toast(a.notice)
		a.notice = ""
	}
	if a.pat == "" {
		a.loginPage(c)
		return
	}
	if c.Shortcut(ui.Cmd, ui.KeyK) {
		a.palette = !a.palette
	}
	if c.Shortcut(ui.Cmd, ui.KeyN) {
		a.router.Push("/create")
	}
	if c.Shortcut(ui.Cmd|ui.Ctrl, ui.KeyS) {
		a.collapsed = !a.collapsed
	}
	bar := c.TitleBar()
	c.Root().Background(ct.Background)
	row := ui.Row(c).Fill().AlignItems(ui.Stretch)
	shown := row.Animate("sidebar", visible(!a.collapsed), 250*time.Millisecond)
	row.Children(func() {
		// A floating panel inset from the window, as macOS sidebars are; it slides out to the left as it hides.
		total := (sidebarWidth + sidebarInset) * shown
		// SetTheme applies to widgets built after it: the sidebar is always dark, the content follows the chosen theme.
		c.SetTheme(&st)
		ui.Row(c).Width(total).Shrink(0).AlignItems(ui.Stretch).Clip().Children(func() {
			ui.Column(c).Width(sidebarWidth).Shrink(0).Margin(sidebarInset, 0, sidebarInset, sidebarInset+total-(sidebarWidth+sidebarInset)).
				Radius(12).Border(1, st.Border).Background(st.Background).Shadow(0, 2, 12, 0, ui.RGBA(0, 0, 0, 0.25)).
				TextColor(st.Text). // the Sidebar paints labels with the frame's last theme otherwise
				Clip().Children(func() { a.sidebar(c) })
		})
		c.SetTheme(&ct)
		ui.Column(c).Grow(1).MinWidth(0).Children(func() {
			// Clear the traffic lights and the toggle while the sidebar is hidden.
			a.topbar(c, 20+(1-shown)*(bar.Left+36))
			a.pages(c)
		})
	})
	// The toggle sits over the sidebar while it shows, over the content's title bar once hidden.
	if !a.collapsed {
		c.SetTheme(&st)
	}
	a.sidebarToggle(c)
	c.SetTheme(&ct)
	a.paletteModal(c)
}

// sidebarToggle sits next to the traffic lights whether the sidebar shows or not.
func (a *App) sidebarToggle(c *ui.Context) {
	t := c.Theme()
	bar := c.TitleBar()
	label := "Hide Sidebar"
	if a.collapsed {
		label = "Show Sidebar"
	}
	btn := ui.ButtonBase(c.Key("sidebar-toggle")).Absolute().Left(bar.Left+8).Top((TitleBarHeight-28)/2).Size(32, 28).
		Radius(6).Center().TextColor(t.TextMuted).Label(label).Tooltip(label + "  ⌃⌘S")
	if btn.Hovered() {
		btn.Background(t.SurfaceHover)
	}
	btn.Children(func() { ui.Icon(c, iconSidebar).Size(16, 16) })
	btn.OnClick(func() { a.collapsed = !a.collapsed })
}

func (a *App) pages(c *ui.Context) {
	a.router.View(c, func(r *ui.Route) {
		switch {
		case r.Match("/"):
			r.Title("Dashboard")
			a.dashboard(c)
		case r.Match("/jobs"):
			r.Title("Sync Jobs")
			a.jobsPage(c)
		case r.Match("/create"):
			r.Title("New Sync Job")
			a.createPage(c)
		case r.Match("/jobs/{id}/edit"):
			r.Title("Edit Job")
			a.editPage(c, atoi(r.Param("id")))
		case r.Match("/jobs/{id}/report"):
			r.Title("Report")
			a.reportPage(c, atoi(r.Param("id")))
		case r.Match("/jobs/{id}"):
			r.Title("Job")
			a.jobPage(c, atoi(r.Param("id")))
		case r.Match("/logs"):
			r.Title("Logs")
			a.logsPage(c)
		case r.Match("/mappings"):
			r.Title("Mappings")
			comingSoon(c, "Mappings", "Reusable field and user mappings shared across jobs.")
		case r.Match("/analytics"):
			r.Title("Analytics")
			comingSoon(c, "Analytics", "Sync volume and failure trends over time.")
		case r.Match("/settings"):
			r.Title("Settings")
			a.settingsPage(c)
		default:
			emptyState(c, "Page not found", a.router.Path())
		}
	}).Grow(1).MinHeight(0)
}

func (a *App) syncNow(id int) {
	j := a.store.Job(id)
	if j == nil || j.Status != syncjob.Active || a.running[id] {
		return
	}
	conn := a.connection() // an incomplete one comes back as a failed run naming what's missing
	a.running[id] = true
	a.store.Log(id, "Sync started")
	job := *j // copied on the UI thread; the worker never touches App state
	var run syncjob.Run
	a.Async(func() {
		ctx, cancel := context.WithTimeout(context.Background(), syncTimeout)
		defer cancel()
		run = a.engine.Sync(ctx, conn, job)
	}, func() {
		delete(a.running, id)
		if a.store.Job(id) == nil {
			return // deleted while syncing
		}
		a.store.AddRun(run)
		summary := fmtRunSummary(run)
		if run.Error != "" {
			summary = "failed: " + run.Error
		}
		a.store.Log(id, "Sync "+summary)
		a.notice = job.Name + ": " + summary
	})
}

// connection is a snapshot of Settings and secrets for one run.
func (a *App) connection() syncjob.Connection {
	s := a.store.Settings
	return syncjob.Connection{ADOOrg: s[setADOOrg], PAT: a.pat, JiraURL: s[setJiraURL], JiraEmail: s[setJiraEmail],
		JiraToken: a.jiraToken, JQLExtra: s[setJQLExtra], JiraKeyField: s[setJiraKeyField]}
}

func (a *App) logout() {
	if err := a.secrets.PAT.Delete(); err != nil {
		a.notice = "Couldn't remove the PAT from Keychain: " + err.Error()
	}
	a.pat, a.remember = "", false
	a.login = loginForm{remember: true}
	a.router.Replace("/")
}
