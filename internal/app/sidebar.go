package app

import (
	"fmt"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/todo"
)

var filters = []struct {
	filter todo.Filter
	label  string
}{
	{todo.All, "All"},
	{todo.Active, "Active"},
	{todo.Done, "Completed"},
}

func (a *App) sidebar(c *ui.Context, vibrant bool) {
	// Room for the traffic lights.
	ui.Box(c).Height(TitleBarHeight).Shrink(0).DragWindow()
	list := ui.Sidebar(c, &a.filter, func() {
		ui.SidebarSection(c, "Todos", nil, func() {
			for _, f := range filters {
				ui.SidebarItem(c, string(f.filter), nil, f.label).Children(func() {
					ui.Badge(c, fmt.Sprint(a.todos.Count(f.filter)))
				})
			}
		})
	}).Grow(1).Label("Filters")
	if vibrant {
		list.Background(ui.Transparent)
	}
}

func (a *App) title() string {
	for _, f := range filters {
		if string(f.filter) == a.filter && f.filter != todo.All {
			return f.label
		}
	}
	return "All Todos"
}
