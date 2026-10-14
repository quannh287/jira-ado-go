package app

import (
	"cmp"
	"fmt"
	"strings"

	"github.com/egoist/mygo/ui"
)

var nav = []struct {
	path, label string
	icon        *ui.SVG
}{
	{"/", "Dashboard", iconDashboard},
	{"/jobs", "Sync Jobs", iconSync},
	{"/logs", "Logs", iconLogs},
	{"/mappings", "Mappings", iconLink},
	{"/analytics", "Analytics", iconChart},
	{"/settings", "Settings", iconGear},
}

// section maps a deep path to the sidebar item it belongs to.
func section(path string) string {
	switch {
	case path == "/create":
		return "/"
	case strings.HasPrefix(path, "/jobs"):
		return "/jobs"
	}
	return path
}

func (a *App) sidebar(c *ui.Context) {
	t := c.Theme()
	// Room for the traffic lights, which sit inside the inset panel.
	ui.Box(c).Height(TitleBarHeight - sidebarInset).Shrink(0).DragWindow()
	page := section(a.router.Path())
	list := ui.Sidebar(c, &page, func() {
		ui.SidebarSection(c, "Jira → ADO", nil, func() {
			for _, n := range nav {
				item := ui.SidebarItem(c, n.path, n.icon, n.label)
				if n.path == "/jobs" {
					item.Children(func() { ui.Badge(c, fmt.Sprint(len(a.store.Jobs))) })
				}
			}
		})
	}).Grow(1).Label("Navigation").Background(ui.Transparent) // the panel paints one background for the whole sidebar
	if list.Changed() {
		a.router.Push(page)
	}

	ui.Row(c).Padding(10, 12).Gap(8).AlignItems(ui.Center).Children(func() {
		name := cmp.Or(a.store.Settings[setADOUser], "ADO User")
		ui.Avatar(c, name, nil)
		ui.Column(c).Grow(1).MinWidth(0).Children(func() {
			ui.Text(c, name).FontSize(12).Bold().SingleLine()
			ui.Text(c, a.store.Settings[setADOOrg]).FontSize(11).TextColor(t.TextMuted).SingleLine()
		})
		ui.MenuButton(c.Key("account"), "", func(m *ui.Menu) {
			if m.Item("Sign Out").Chosen() {
				a.logout()
			}
		}).Label("Account")
	})
}

func (a *App) topbar(c *ui.Context, left float32) {
	bar := c.TitleBar()
	ui.Row(c).Height(TitleBarHeight).Shrink(0).AlignItems(ui.Center).Gap(10).
		Padding(0, bar.Right+16, 0, left).DragWindow().Children(func() {
		labels, paths := a.crumbs()
		chosen := len(labels) - 1
		if ui.Breadcrumbs(c, labels, &chosen).Label("Location").Grow(1).MinWidth(0).Changed() {
			a.router.Push(paths[chosen])
		}
		dark := c.Theme().Dark
		themeIcon, themeLabel := iconMoon, "Dark Theme"
		if dark {
			themeIcon, themeLabel = iconSun, "Light Theme"
		}
		capsule(c, func() {
			toolButton(c, "theme", themeIcon, themeLabel).OnClick(func() { a.toggleTheme(dark) })
			toolButton(c, "new", iconPlus, "New Sync Job  ⌘N").OnClick(func() { a.router.Push("/create") })
		})
		searchPill(c).OnClick(func() { a.palette = true })
	})
}

func (a *App) crumbs() (labels, paths []string) {
	add := func(l, p string) { labels, paths = append(labels, l), append(paths, p) }
	parts := strings.Split(strings.Trim(a.router.Path(), "/"), "/")
	switch parts[0] {
	case "":
		add("Dashboard", "/")
	case "create":
		add("Dashboard", "/")
		add("New Sync Job", "/create")
	case "jobs":
		add("Sync Jobs", "/jobs")
		if len(parts) > 1 {
			name := "Job " + parts[1]
			if j := a.store.Job(atoi(parts[1])); j != nil {
				name = j.Name
			}
			add(name, "/jobs/"+parts[1])
		}
		if len(parts) > 2 {
			label := "Report"
			if parts[2] == "edit" {
				label = "Edit"
			}
			add(label, a.router.Location())
		}
	default:
		for _, n := range nav {
			if n.path == "/"+parts[0] {
				add(n.label, n.path)
			}
		}
	}
	if len(labels) == 0 {
		add(a.router.Path(), a.router.Path())
	}
	return
}

type paletteEntry struct{ label, hint, path string }

func (a *App) paletteEntries() []paletteEntry {
	var all []paletteEntry
	for _, n := range nav {
		all = append(all, paletteEntry{n.label, "Page", n.path})
	}
	all = append(all, paletteEntry{"New Sync Job", "Action", "/create"})
	for _, j := range a.store.Jobs {
		all = append(all, paletteEntry{j.Name, j.JiraKey + " → " + j.ADOProject, fmt.Sprintf("/jobs/%d", j.ID)})
	}
	q := strings.ToLower(strings.TrimSpace(a.query))
	var out []paletteEntry
	for _, e := range all {
		if q == "" || strings.Contains(strings.ToLower(e.label+" "+e.hint), q) {
			out = append(out, e)
		}
	}
	return out
}

func (a *App) paletteModal(c *ui.Context) {
	t := c.Theme()
	ui.Modal(c, &a.palette, func() {
		go_ := func(p string) {
			a.palette, a.query = false, ""
			a.router.Push(p)
		}
		entries := a.paletteEntries()
		ui.Column(c).Width(460).Gap(8).Children(func() {
			if ui.SearchField(c.Key("palette"), &a.query).Label("Search pages and jobs").AutoFocus().Submitted() && len(entries) > 0 {
				go_(entries[0].path)
			}
			ui.Scroll(c).MaxHeight(320).Children(func() {
				for _, e := range entries {
					row := ui.ButtonBase(c.Key(e.path)).Row().Padding(8, 10).Radius(6).Gap(8).Label(e.label)
					if row.Hovered() || row.Focused() {
						row.Background(t.SurfaceHover)
					}
					row.Children(func() {
						ui.Text(c, e.label).Grow(1).SingleLine()
						ui.Text(c, e.hint).FontSize(12).TextColor(t.TextMuted).SingleLine()
					})
					path := e.path
					row.OnClick(func() { go_(path) })
				}
				if len(entries) == 0 {
					ui.Text(c, "No matches").TextColor(t.TextMuted).Padding(12)
				}
			})
		})
	})
}

func last4(s string) string {
	if len(s) <= 4 {
		return s
	}
	return s[len(s)-4:]
}
