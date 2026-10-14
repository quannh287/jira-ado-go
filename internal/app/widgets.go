package app

import (
	"fmt"
	"strconv"
	"time"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/syncjob"
)

func icon(shapes string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">` + shapes + `</svg>`))
}

var (
	iconDashboard   = icon(`<rect x="2" y="2" width="5" height="5" rx="1"/><rect x="9" y="2" width="5" height="5" rx="1"/><rect x="2" y="9" width="5" height="5" rx="1"/><rect x="9" y="9" width="5" height="5" rx="1"/>`)
	iconSync        = icon(`<path d="M13.5 6.5A5.5 5.5 0 0 0 3.2 4.8M2.5 9.5a5.5 5.5 0 0 0 10.3 1.7"/><path d="M3 2v3h3M13 14v-3h-3"/>`)
	iconLogs        = icon(`<path d="M5 4h8M5 8h8M5 12h8"/><circle cx="2.5" cy="4" r=".5"/><circle cx="2.5" cy="8" r=".5"/><circle cx="2.5" cy="12" r=".5"/>`)
	iconLink        = icon(`<path d="M6.5 9.5l3-3"/><path d="M7 4.5l1-1a2.8 2.8 0 0 1 4 4l-1 1M9 11.5l-1 1a2.8 2.8 0 0 1-4-4l1-1"/>`)
	iconChart       = icon(`<path d="M2 14h12"/><rect x="3" y="8" width="2" height="4"/><rect x="7" y="5" width="2" height="7"/><rect x="11" y="2.5" width="2" height="9.5"/>`)
	iconGear        = icon(`<circle cx="8" cy="8" r="2"/><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4"/>`)
	iconSidebar     = icon(`<rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M6 2.5v11"/>`)
	iconPlus        = icon(`<path d="M8 3v10M3 8h10"/>`)
	iconSearch      = icon(`<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/>`)
	iconSun         = icon(`<circle cx="8" cy="8" r="3"/><path d="M8 1v1.5M8 13.5V15M1 8h1.5M13.5 8H15M3 3l1 1M12 12l1 1M3 13l1-1M12 4l1-1"/>`)
	iconMoon        = icon(`<path d="M13.5 9.5A5.5 5.5 0 1 1 6.5 2.5a4.5 4.5 0 0 0 7 7z"/>`)
	iconChevron     = icon(`<path d="M6 4l4 4-4 4"/>`)
	iconChevronDown = icon(`<path d="M4 6l4 4 4-4"/>`)
)

// page is the scaffold every page shares: title row, optional actions, then content.
func page(c *ui.Context, title, subtitle string, actions func(), body func()) {
	t := c.Theme()
	ui.Column(c).Fill().Padding(20, 24).Gap(16).Children(func() {
		ui.Row(c).Gap(12).AlignItems(ui.Center).Children(func() {
			ui.Column(c).Grow(1).MinWidth(0).Gap(2).Children(func() {
				ui.Text(c, title).FontSize(20).Bold().SingleLine()
				if subtitle != "" {
					ui.Text(c, subtitle).FontSize(12).TextColor(t.TextMuted).SingleLine()
				}
			})
			if actions != nil {
				actions()
			}
		})
		body()
	})
}

func card(c *ui.Context) ui.Element {
	t := c.Theme()
	return ui.Column(c).Padding(14, 16).Gap(4).Radius(10).Background(t.Surface).Border(1, t.Border)
}

func stat(c *ui.Context, label, value string, color ui.Color) {
	t := c.Theme()
	card(c).Children(func() {
		ui.Text(c, label).FontSize(12).TextColor(t.TextMuted)
		ui.Text(c, value).FontSize(24).Bold().TextColor(color)
	})
}

func pill(c *ui.Context, text string, color ui.Color) ui.Element {
	return ui.Text(c, text).FontSize(11).Bold().SingleLine().Padding(2, 8).Radius(10).
		Background(color.Alpha(0.15)).TextColor(color)
}

func jobStatusColor(t *ui.Theme, s syncjob.Status) ui.Color {
	if s == syncjob.Active {
		return t.Success
	}
	return t.Warning
}

func runStatusColor(t *ui.Theme, s syncjob.RunStatus) ui.Color {
	switch s {
	case syncjob.Success:
		return t.Success
	case syncjob.Partial:
		return t.Warning
	}
	return t.Danger
}

func outcomeColor(t *ui.Theme, o syncjob.Outcome) ui.Color {
	switch o {
	case syncjob.Created:
		return t.Success
	case syncjob.Updated:
		return t.Accent
	case syncjob.Failed:
		return t.Danger
	}
	return t.TextMuted
}

// kv is a read-only row of a Form.
func kv(c *ui.Context, label, value string) {
	ui.Field(c, label, func() { ui.Text(c, value).Selectable() })
}

func emptyState(c *ui.Context, title, detail string) {
	t := c.Theme()
	ui.Column(c).Fill().Center().Gap(6).Padding(24).Children(func() {
		ui.Text(c, title).FontSize(15).Bold()
		ui.Text(c, detail).FontSize(12).TextColor(t.TextMuted)
	})
}

func comingSoon(c *ui.Context, title, detail string) {
	page(c, title, "", nil, func() { emptyState(c, "Coming soon", detail) })
}

func mono(c *ui.Context, s string) ui.Element {
	t := c.Theme()
	return ui.Text(c, s).Font("monospace").FontSize(11).Selectable().Padding(8, 10).Radius(6).Background(t.Surface).Border(1, t.Border)
}

func ago(t, now time.Time) string {
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
	return fmt.Sprintf("%dd ago", int(d.Hours()/24))
}

func fmtRunSummary(r syncjob.Run) string {
	return fmt.Sprintf("%d created, %d updated, %d skipped, %d failed",
		r.Count(syncjob.Created), r.Count(syncjob.Updated), r.Count(syncjob.Skipped), r.Count(syncjob.Failed))
}

func fmtDuration(d time.Duration) string {
	return d.Round(100 * time.Millisecond).String()
}

func visible(b bool) float32 {
	if b {
		return 1
	}
	return 0
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

// capsule groups toolbar buttons in one pill, as macOS toolbars do.
func capsule(c *ui.Context, fn func()) {
	t := c.Theme()
	ui.Row(c).Height(34).Padding(0, 4).Gap(2).AlignItems(ui.Center).Radius(17).Background(t.Surface).Border(1, t.Border).Children(fn)
}

// toolButton is an icon-only button inside a capsule; label names it for the tooltip and screen readers.
func toolButton(c *ui.Context, key string, svg *ui.SVG, label string) ui.Element {
	t := c.Theme()
	b := ui.ButtonBase(c.Key(key)).Size(32, 28).Radius(14).Center().Label(label).Tooltip(label).TextColor(t.Text)
	if b.Hovered() {
		b.Background(t.SurfaceHover)
	}
	return b.Children(func() { ui.Icon(c, svg).Size(16, 16) })
}

// searchPill is the toolbar's search capsule; it opens the ⌘K palette.
func searchPill(c *ui.Context) ui.Element {
	t := c.Theme()
	b := ui.ButtonBase(c.Key("search")).Row().Width(240).Height(34).Padding(0, 12).Gap(8).AlignItems(ui.Center).
		Radius(17).Background(t.Surface).Border(1, t.Border).TextColor(t.TextMuted).Label("Search  ⌘K")
	if b.Hovered() {
		b.Background(t.SurfaceHover)
	}
	return b.Children(func() {
		ui.Icon(c, iconSearch).Size(14, 14)
		ui.Text(c, "Search jobs and pages").Grow(1).SingleLine()
		keycap(c, "⌘K")
	})
}

// keycap shows a shortcut as macOS menus and empty states do.
func keycap(c *ui.Context, keys string) {
	t := c.Theme()
	ui.Text(c, keys).FontSize(11).TextColor(t.TextMuted).Padding(1, 6).Radius(5).Background(t.SurfaceHover).Shrink(0)
}

// emptyHint is an empty state with an icon and keyboard hints, as native Mac apps show.
func emptyHint(c *ui.Context, svg *ui.SVG, title string, hints ...[2]string) {
	t := c.Theme()
	ui.Column(c).Fill().Center().Gap(10).Padding(24).Children(func() {
		ui.Icon(c, svg).Size(40, 40).TextColor(t.TextMuted.Alpha(0.6))
		ui.Text(c, title).FontSize(15).Bold().TextColor(t.TextMuted)
		for _, h := range hints {
			ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
				keycap(c, h[0])
				ui.Text(c, h[1]).FontSize(12).TextColor(t.TextMuted.Alpha(0.8))
			})
		}
	})
}

// switchField is a form field whose switch and description share one line, so the label lines up with the switch;
// a Field description below a switch drops the label to the description's line. It returns the switch, for OnChange.
func switchField(c *ui.Context, label, key string, on *bool, desc string) ui.Element {
	t := c.Theme()
	var sw ui.Element
	ui.Field(c, label, func() {
		ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
			sw = ui.Switch(c.Key(key), on)
			ui.Text(c, desc).FontSize(12).TextColor(t.TextMuted).Grow(1).MinWidth(0)
		})
	})
	return sw
}
