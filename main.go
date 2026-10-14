package main

import (
	"log"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"jira-ado/internal/app"
)

func main() {
	a := app.New()
	mygo.App.WhenReady(func() {
		mygo.NewWindow(mygo.WindowOptions{
			Title:          "jira-ado",
			Width:          880,
			Height:         600,
			MinWidth:       560,
			MinHeight:      400,
			StateKey:       "main",
			TitleBarStyle:  mygo.TitleBarHiddenInset,
			TitleBarHeight: app.TitleBarHeight,
			Vibrancy:       mygo.VibrancySidebar,
			Content:        ui.View(a.View),
		})
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}
