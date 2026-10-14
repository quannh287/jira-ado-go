package main

import (
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"jira-ado/internal/app"
	"jira-ado/internal/keychain"
	"jira-ado/internal/syncer"
	"jira-ado/internal/syncjob"
)

const keychainService = "com.example.jiraado"

func main() {
	dir, err := mygo.App.Path(mygo.PathUserData)
	if err != nil {
		log.Fatal(err)
	}
	store, err := syncjob.Open(filepath.Join(dir, "jira-ado.db"), time.Now)
	if err != nil {
		log.Fatal(err)
	}
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

	mygo.App.WhenReady(func() {
		win := mygo.NewWindow(mygo.WindowOptions{
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
		a.Async = func(work, done func()) {
			go func() {
				work()
				win.Update(done)
			}()
		}
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}
