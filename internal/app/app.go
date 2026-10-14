// Package app is the native UI: state the window shows and the views drawing it.
package app

import (
	"github.com/egoist/mygo/ui"

	"jira-ado/internal/todo"
)

const (
	TitleBarHeight = 52
	sidebarWidth   = 220
)

type App struct {
	todos  todo.List
	draft  string
	filter string // a todo.Filter; string because ui.Sidebar binds *string
	list   ui.ListState
}

func New() *App {
	a := &App{filter: string(todo.All)}
	for _, t := range []string{"Review SE-485 bugs", "Sync PBIs from ADO", "Write sprint report"} {
		a.todos.Add(t)
	}
	return a
}

func (a *App) View(c *ui.Context) {
	t := c.Theme()
	vibrant := c.Vibrancy()
	if vibrant {
		c.Root().Background(ui.Transparent)
	}
	ui.Row(c).Fill().AlignItems(ui.Stretch).Children(func() {
		side := ui.Column(c).Width(sidebarWidth).Shrink(0)
		if !vibrant {
			side.Background(t.Surface)
		}
		side.Children(func() { a.sidebar(c, vibrant) })
		ui.Box(c).Width(1).Background(t.Border)
		a.pane(c)
	})
}
