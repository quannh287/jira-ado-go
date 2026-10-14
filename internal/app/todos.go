package app

import (
	"fmt"
	"strings"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/todo"
)

func (a *App) pane(c *ui.Context) {
	t := c.Theme()
	bar := c.TitleBar()
	ui.Column(c).Grow(1).MinWidth(0).Background(t.Background).Children(func() {
		ui.Row(c).Height(TitleBarHeight).Shrink(0).AlignItems(ui.Center).Gap(12).
			Padding(0, bar.Right+16, 0, 20).DragWindow().Children(func() {
			ui.Text(c, a.title()).FontSize(15).Bold().SingleLine()
			ui.Text(c, fmt.Sprintf("%d left", a.todos.Count(todo.Active))).FontSize(12).TextColor(t.TextMuted)
			ui.Spacer(c)
			ui.Button(c.Key("clear"), "Clear Completed").Disabled(a.todos.Count(todo.Done) == 0).OnClick(a.todos.ClearDone)
		})
		ui.Divider(c)

		ui.Row(c).Padding(12, 20).Gap(8).Children(func() {
			in := ui.TextInput(c.Key("draft"), &a.draft).Placeholder("New todo").Label("New todo").AutoFocus().Grow(1)
			add := ui.PrimaryButton(c.Key("add"), "Add").Disabled(strings.TrimSpace(a.draft) == "")
			if (in.Submitted() || add.Clicked()) && a.todos.Add(a.draft) {
				a.draft = ""
			}
		})

		rows := a.todos.Indices(todo.Filter(a.filter))
		a.list.Key = func(i int) any { return a.todos.Items[rows[i]].ID }
		a.list.Label = func(i int) string { return a.todos.Items[rows[i]].Title }
		ui.List(c, &a.list, len(rows), func(i int) { a.row(c, rows[i]) }).Grow(1).Padding(0, 12, 12, 12).Children(func() {
			if len(rows) == 0 {
				ui.Text(c, "Nothing here").TextColor(t.TextMuted).Padding(24).AlignSelf(ui.Center)
			}
		})
	})
}

func (a *App) row(c *ui.Context, i int) {
	t := c.Theme()
	item := a.todos.Items[i]
	row := ui.Row(c).AlignItems(ui.Center).Gap(8).Padding(6, 8).Radius(6)
	hovered := row.Hovered()
	if hovered {
		row.Background(t.SurfaceHover)
	}
	row.Children(func() {
		ui.Checkbox(c, &a.todos.Items[i].Done, item.Title).Grow(1)
		// Deferred so the slice isn't mutated while the list is being built.
		ui.Button(c.Key("delete"), "Delete").Label("Delete " + item.Title).Opacity(opacity(hovered)).
			OnClick(func() { a.todos.Remove(item.ID) })
	})
}

func opacity(visible bool) float32 {
	if visible {
		return 1
	}
	return 0
}
