// Package app is the native UI of the Jira→ADO sync tool.
package app

import (
	"cmp"
	"context"
	"fmt"
	"slices"
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
	setNotify       = "notify"
	setAppIcon      = appicon.SettingKey
)

type App struct {
	// Async runs work off the UI thread, then done on it; the default runs both inline, for tests.
	Async func(work, done func())
	// Post runs fn on the UI thread from any goroutine (Window.Update); inline by default, for tests.
	Post func(fn func())
	// LogPath is the diagnostic log file, shown in Settings so a problem can be traced.
	LogPath string
	// Notifier, if set, tells the user when a run finishes.
	Notifier Notifier

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
	mappings  mappingsForm
	catalog   catalogState
	palette   bool
	collapsed bool
	query     string
	draft     draft
	running   map[int]bool
	live      map[int]syncjob.Progress // the run in flight per job, for the live report
	cancels   map[int]context.CancelFunc
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
		Post:     func(fn func()) { fn() },
		live:     map[int]syncjob.Progress{},
		cancels:  map[int]context.CancelFunc{},
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
			a.mappingsPage(c)
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

func (a *App) syncNow(id int) { a.startRun(id, syncjob.RunOptions{}) }

// dryRun reads Jira and ADO like a sync but writes nothing; its report shows what a sync would send.
func (a *App) dryRun(id int) { a.startRun(id, syncjob.RunOptions{DryRun: true}) }

// retryFailed reruns only the failed tickets of r, without touching the cursor.
func (a *App) retryFailed(r syncjob.Run) {
	if keys := r.FailedKeys(); len(keys) > 0 {
		a.startRun(r.JobID, syncjob.RunOptions{Keys: keys})
	}
}

// cancelRun stops a job's run; it ends at the next issue, with the cursor at its last checkpoint.
func (a *App) cancelRun(id int) {
	if cancel := a.cancels[id]; cancel != nil {
		cancel()
		a.store.Log(id, "Cancel requested")
	}
}

func (a *App) startRun(id int, opts syncjob.RunOptions) {
	j := a.store.Job(id)
	if j == nil || j.Status != syncjob.Active || a.running[id] {
		return
	}
	conn := a.connection() // an incomplete one comes back as a failed run naming what's missing
	kind := map[bool]string{true: "Dry run"}[opts.DryRun]
	if len(opts.Keys) > 0 {
		kind = fmt.Sprintf("Retry of %d failed tickets", len(opts.Keys))
	}
	label := cmp.Or(kind, "Sync")
	a.running[id] = true
	a.live[id] = syncjob.Progress{Run: syncjob.Run{JobID: id, Started: a.now(), Kind: map[bool]string{true: syncjob.KindDryRun}[opts.DryRun]}}
	a.store.Log(id, label+" started")
	job := a.effectiveJob(*j) // copied on the UI thread; the worker never touches App state
	ctx, cancel := context.WithTimeout(context.Background(), syncTimeout)
	a.cancels[id] = cancel
	// Snapshots arrive on the worker; Post hands them to the UI thread, which redraws the live report.
	opts.OnProgress = func(p syncjob.Progress) {
		a.Post(func() {
			if a.running[id] { // a late snapshot after done must not resurrect the live run
				a.live[id] = p
			}
		})
	}
	var run syncjob.Run
	a.Async(func() {
		defer cancel()
		run = a.engine.Sync(ctx, conn, job, opts)
	}, func() {
		delete(a.running, id)
		delete(a.live, id)
		delete(a.cancels, id)
		if a.store.Job(id) == nil {
			return // deleted while syncing
		}
		rid := a.store.AddRun(run)
		run.ID = rid
		a.notifyRun(job, run)
		// Someone watching the live run now sees the saved one in its place.
		if a.router.Path() == fmt.Sprintf("/jobs/%d/report", id) && a.router.Query("run") == liveRun {
			a.router.Replace(fmt.Sprintf("/jobs/%d/report?run=%d", id, rid))
		}
		summary := fmtRunSummary(run)
		if run.Error != "" {
			summary = "failed: " + run.Error
		}
		a.store.Log(id, label+" "+summary)
		a.notice = job.Name + ": " + summary
	})
}

// Running is the number of runs in flight, asked before quitting.
func (a *App) Running() int { return len(a.running) }

// Tick starts every active Scheduler job whose interval has passed since its last run (or its creation); main calls it each minute.
func (a *App) Tick() {
	if a.pat == "" {
		return // signed out: every run would fail on the missing PAT
	}
	now := a.now()
	var due []int
	for _, j := range a.store.Jobs {
		if j.Type != syncjob.Scheduler || j.Status != syncjob.Active || a.running[j.ID] {
			continue
		}
		last := j.Created
		if r, ok := a.store.LastRun(j.ID); ok {
			last = r.Started
		}
		if now.Sub(last) >= j.Filters.Every() {
			due = append(due, j.ID)
		}
	}
	for _, id := range due {
		a.syncNow(id)
	}
}

// effectiveJob adds the shared user mapping after the job's own, so a job-specific entry wins.
func (a *App) effectiveJob(j syncjob.Job) syncjob.Job {
	j.Filters.Users = append(slices.Clone(j.Filters.Users), a.store.SharedUsers()...)
	return j
}

// connection is a snapshot of Settings and secrets for one run.
func (a *App) connection() syncjob.Connection {
	s := a.store.Settings
	return syncjob.Connection{ADOOrg: s[setADOOrg], PAT: a.pat, JiraURL: s[setJiraURL], JiraEmail: s[setJiraEmail],
		JiraToken: a.jiraToken, JQLExtra: s[setJQLExtra], JiraKeyField: s[setJiraKeyField], Rules: a.store.Rules()}
}

func (a *App) logout() {
	if err := a.secrets.PAT.Delete(); err != nil {
		a.notice = "Couldn't remove the PAT from Keychain: " + err.Error()
	}
	a.pat, a.remember = "", false
	a.login = loginForm{remember: true}
	a.router.Replace("/")
}
