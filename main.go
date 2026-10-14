package main

import (
	"cmp"
	"errors"
	"log"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"time"
	_ "time/tzdata" // the Jira account zone for JQL dates; Windows has no zoneinfo of its own

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"jira-ado/internal/app"
	"jira-ado/internal/appicon"
	"jira-ado/internal/applog"
	"jira-ado/internal/keychain"
	"jira-ado/internal/syncer"
	"jira-ado/internal/syncjob"
)

const keychainService = "com.example.jiraado"

func main() {
	// Logging first, so even a failure to open the database is in the file.
	logPath := ""
	if logs, err := mygo.App.Path(mygo.PathLogs); err == nil {
		if p, closer, err := applog.Setup(logs); err == nil {
			logPath = p
			defer closer.Close()
		} else {
			log.Printf("file log unavailable: %v", err)
		}
	}
	slog.Info("app start", "version", cmp.Or(mygo.App.Version(), "dev"), "os", runtime.GOOS, "arch", runtime.GOARCH, "demo", os.Getenv("JIRA_ADO_DEMO") == "1")
	dir, err := mygo.App.Path(mygo.PathUserData)
	if err != nil {
		fatal("app data dir", err)
	}
	dbPath := filepath.Join(dir, "jira-ado.db")
	store, err := syncjob.Open(dbPath, time.Now)
	if err != nil {
		fatal("open database "+dbPath, err)
	}
	slog.Info("database open", "path", dbPath, "jobs", len(store.Jobs), "runs", len(store.Runs))
	defer store.Close()

	var engine syncjob.Engine = syncer.New(store.State(), time.Now)
	if os.Getenv("JIRA_ADO_DEMO") == "1" {
		// Demo: generated tickets, no Jira or ADO calls.
		engine = syncjob.NewFake(1500*time.Millisecond, time.Now)
		if len(store.Jobs) == 0 {
			syncjob.Seed(store, syncjob.NewFake(0, time.Now), time.Now())
		}
	}
	keys := app.Keys{
		PAT:  keychain.Secret{Service: keychainService, Account: "ado-pat"},
		Jira: keychain.Secret{Service: keychainService, Account: "jira-api-token"},
	}
	a := app.New(engine, store, keys, time.Now)
	a.LogPath = logPath
	a.Notifier = &desktopNotifier{}

	// Registered before Run, so the click that relaunched the app is received too; the window may not exist yet.
	var win *mygo.Window
	var pending string
	mygo.App.OnNotificationClick(func(id string) {
		slog.Info("notification clicked", "id", id, "window", win != nil)
		if win == nil {
			pending = id
			return
		}
		win.Show()
		win.Focus()
		a.Post(func() { slog.Info("notification opened", "id", id, "page", a.OpenNotification(id)) })
	})
	// What the user sees in the app needn't wait in Notification Center.
	mygo.App.OnDidBecomeActive(mygo.ClearNotifications)

	mygo.App.WhenReady(func() {
		win = mygo.NewWindow(mygo.WindowOptions{
			Title:           "jira-ado",
			Width:           1180,
			Height:          760,
			MinWidth:        900,
			MinHeight:       560,
			StateKey:        "main",
			TitleBarStyle:   mygo.TitleBarHiddenInset,
			TitleBarHeight:  app.TitleBarHeight,
			BackgroundColor: "light-dark(#ffffff, #1c1c1e)", // shown before the first frame
			Content:         ui.View(a.View),
		})
		appicon.SetIcon = mygo.App.Dock.SetIcon
		appicon.Apply(store.Settings[appicon.SettingKey])
		a.Post = win.Update
		if pending != "" {
			slog.Info("notification opened at launch", "id", pending, "page", a.OpenNotification(pending))
		}
		a.Async = func(work, done func()) {
			go func() {
				// A panic in background work is logged with its stack; done still runs so the UI leaves its busy state.
				defer func() {
					if p := recover(); p != nil {
						applog.Recovered("background work", p)
					}
					win.Update(done)
				}()
				work()
			}()
		}
	})
	if err := mygo.App.Run(); err != nil {
		fatal("app run", err)
	}
	slog.Info("app quit")
}

func fatal(what string, err error) {
	slog.Error("fatal", "what", what, "err", err)
	os.Exit(1)
}

// desktopNotifier shows notifications through MyGo; Show may wait for the user's first permission answer, so it runs off the UI thread.
type desktopNotifier struct{ denied atomic.Bool }

func (n *desktopNotifier) Supported() bool { return mygo.NotificationsSupported() }

func (n *desktopNotifier) Notify(id, title, subtitle, body string) {
	if !n.Supported() {
		return
	}
	go func() {
		err := mygo.NewNotification(mygo.NotificationOptions{ID: id, Title: title, Subtitle: subtitle, Body: body, Group: "runs"}).Show()
		switch {
		case errors.Is(err, mygo.ErrNotificationsDenied):
			if !n.denied.Swap(true) { // said once per launch
				slog.Warn("notifications denied by the user")
			}
		case err != nil:
			slog.Error("show notification", "id", id, "err", err)
		default:
			slog.Info("notification shown", "id", id)
		}
	}()
}
