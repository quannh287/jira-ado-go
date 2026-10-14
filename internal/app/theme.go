package app

import "github.com/egoist/mygo/ui"

// Theme modes, stored under setTheme.
const (
	themeSystem = "system"
	themeLight  = "light"
	themeDark   = "dark"
)

var themeModes = []string{themeSystem, themeLight, themeDark}

// contentTheme is the system's theme, or the light/dark one the user chose, keeping the system accent and metrics.
func (a *App) contentTheme(c *ui.Context) ui.Theme {
	sys := *c.Theme()
	mode := a.store.Settings[setTheme]
	if mode != themeLight && mode != themeDark || (mode == themeDark) == sys.Dark {
		return slate(sys)
	}
	base := ui.LightTheme()
	if mode == themeDark {
		base = ui.DarkTheme()
	}
	t := *base
	t.Font, t.FontSize, t.Spacing, t.Radius = sys.Font, sys.FontSize, sys.Spacing, sys.Radius
	if c.Preferences().Accent.A != 0 {
		withAccent(&t, sys.Accent)
	}
	return slate(t)
}

// slate gives a dark content the graphite greys of native macOS apps (e.g. TablePro), lighter than the sidebar.
func slate(t ui.Theme) ui.Theme {
	if t.Dark {
		t.Background = ui.Hex("#24272a")
		t.Surface, t.SurfaceHover, t.SurfacePressed = ui.Hex("#2c2f33"), ui.Hex("#33373b"), ui.Hex("#3a3e42")
		t.Border = ui.Hex("#383c40")
	}
	return t
}

// sidebarTheme is always dark graphite, darker than any content, as the floating sidebar of native macOS apps.
func sidebarTheme(content ui.Theme) ui.Theme {
	t := *ui.DarkTheme()
	t.Font, t.FontSize, t.Spacing, t.Radius = content.Font, content.FontSize, content.Spacing, content.Radius
	if content.Dark {
		withAccent(&t, content.Accent)
	} // in light mode the light default accent is under 4.5:1 on the dark canvas; keep the dark default
	t.Background = ui.Hex("#17191c")
	t.Surface, t.SurfaceHover, t.SurfacePressed = ui.Hex("#202327"), ui.Hex("#272a2e"), ui.Hex("#2d3135")
	t.Border = ui.Hex("#2c3034")
	t.Text, t.TextMuted = ui.Hex("#f7f8f8"), ui.Hex("#8a8f98")
	t.Success = ui.Hex("#27a644")
	return t
}

// withAccent sets the accent and derives its states the way MyGo does for each appearance.
func withAccent(t *ui.Theme, accent ui.Color) {
	white, black := ui.Hex("#ffffff"), ui.Hex("#000000")
	t.Accent = accent
	if t.Dark {
		t.AccentHover, t.AccentPressed = accent.Mix(white, 0.2), accent.Mix(black, 0.15)
	} else {
		t.AccentHover, t.AccentPressed = accent.Mix(black, 0.1), accent.Mix(black, 0.2)
	}
	t.Selection, t.Focus = accent.Alpha(0.4), t.AccentHover.Alpha(0.6)
}

// toggleTheme flips the content between light and dark from whatever shows now.
func (a *App) toggleTheme(dark bool) {
	if dark {
		a.store.SetSetting(setTheme, themeLight)
	} else {
		a.store.SetSetting(setTheme, themeDark)
	}
}
