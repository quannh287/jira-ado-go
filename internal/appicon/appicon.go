// Package appicon holds the selectable app icons and swaps the running app's
// Dock/taskbar icon. The Finder icon of a packaged .app stays resources/icon.png:
// it is read from the bundle, which is never modified at runtime.
package appicon

import (
	_ "embed"
	"log"
)

// SettingKey stores the chosen icon id in the settings table.
const SettingKey = "app_icon"

// Default is the packaged icon (resources/icon.png = design/logo/concept-2).
const Default = "bridge"

type Option struct {
	ID, Name string
	PNG      []byte
}

var (
	//go:embed merge.png
	mergePNG []byte
	//go:embed bridge.png
	bridgePNG []byte
	//go:embed lanes.png
	lanesPNG []byte
)

var Options = []Option{
	{"merge", "Merge", mergePNG},
	{"bridge", "Bridge", bridgePNG},
	{"lanes", "Lane change", lanesPNG},
}

// SetIcon applies a PNG; main sets it to mygo.App.Dock.SetIcon once the app is
// ready. Nil (tests, before launch) makes Apply a no-op.
var SetIcon func(png []byte) error

// Get returns the option for id, falling back to Default for unknown ids.
func Get(id string) Option {
	for _, o := range Options {
		if o.ID == id {
			return o
		}
	}
	return Get(Default)
}

// Apply shows the icon for id (or Default) in the Dock/taskbar.
func Apply(id string) {
	if SetIcon == nil {
		return
	}
	o := Get(id)
	if err := SetIcon(o.PNG); err != nil {
		log.Printf("appicon: set %q: %v", o.ID, err)
	}
}
