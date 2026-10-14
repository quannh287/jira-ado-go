package app

import (
	"bytes"
	"testing"

	"jira-ado/internal/appicon"
)

func TestAppIcon(t *testing.T) {
	var shown []byte
	appicon.SetIcon = func(png []byte) error { shown = png; return nil }
	defer func() { appicon.SetIcon = nil }()

	a, tt := newTestApp()
	a.pat = "abcdefghijklmnopqrstuvwxyz0123456789"
	a.router.Push("/settings")
	tt.Frame()
	must(t, tt.Click("Merge"))
	if a.store.Settings[setAppIcon] != "merge" || !bytes.Equal(shown, appicon.Get("merge").PNG) {
		t.Fatalf("setting %q, applied merge: %v", a.store.Settings[setAppIcon], bytes.Equal(shown, appicon.Get("merge").PNG))
	}
	if appicon.Get("nope").ID != appicon.Default || appicon.Get("").ID != "bridge" {
		t.Fatal("unknown id didn't fall back to bridge")
	}
}
