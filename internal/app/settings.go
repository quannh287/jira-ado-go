package app

import (
	"context"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/egoist/mygo/ui"

	"jira-ado/internal/appicon"
	"jira-ado/internal/syncjob"
)

type settingsForm struct {
	jiraURL, jiraEmail, jiraToken, jqlExtra, keyField string
	checking                                          bool
	result                                            string
}

func (a *App) settingsPage(c *ui.Context) {
	t := c.Theme()
	f := &a.settings
	page(c, "Settings", "", nil, func() {
		ui.Scroll(c).Grow(1).Children(func() {
			ui.Column(c).MaxWidth(720).Gap(16).Children(func() {
				ui.Form(c, func() {
					ui.Fieldset(c, "Appearance", func() {
						mode := slices.Index(themeModes, a.store.Settings[setTheme])
						if mode < 0 {
							mode = 0
						}
						ui.Field(c, "Theme", func() {
							ui.Segmented(c.Key("theme"), &mode, "System", "Light", "Dark").Label("Theme").
								OnChange(func() { a.store.SetSetting(setTheme, themeModes[mode]) })
						}).Description("The content area; the sidebar is always dark.")
						ui.Field(c, "App icon", func() { a.appIconPicker(c) }).
							Description("The Dock icon while the app runs; Finder keeps the packaged icon.")
					})
					ui.Fieldset(c, "Notifications", func() {
						mode := max(slices.Index(notifyModes, a.notifyMode()), 0)
						ui.Field(c, "When a run ends", func() {
							ui.Segmented(c.Key("notify"), &mode, "Every run", "Failures only", "Off").Label("Notify").
								OnChange(func() { a.store.SetSetting(setNotify, notifyModes[mode]) })
						}).Description("A desktop notification with the counts; click it to open the run's report.")
						ui.Field(c, "Test", func() {
							ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
								supported := a.Notifier != nil && a.Notifier.Supported()
								ui.Button(c.Key("testnotify"), "Send Test Notification").Disabled(!supported).OnClick(func() {
									a.Notifier.Notify(testNotificationID, "jira-ado", "Notifications work", "Click to come back to Settings. Run notifications open their report.")
								})
								if !supported {
									ui.Text(c, "Needs the packaged app (DMG or go tool mygo dev)").FontSize(12).TextColor(t.TextMuted)
								}
							})
						}).Description("macOS asks for permission the first time; change it later in System Settings → Notifications.")
					})
					ui.Fieldset(c, "Azure DevOps", func() {
						kv(c, "Organization", a.store.Settings[setADOOrg])
						kv(c, "Signed in as", a.store.Settings[setADOUser])
						ui.Field(c, "Remember PAT", func() {
							ui.Switch(c.Key("remember"), &a.remember).OnChange(a.toggleRemember)
						}).Description("Keep the PAT in the macOS Keychain across launches. Off removes it; you stay signed in until you quit.")
						ui.Field(c, "Jira key field", func() {
							ui.TextInput(c.Key("keyfield"), &f.keyField).Placeholder(syncjob.DefaultJiraKeyField)
						}).Description("ADO field holding \"KEY - id\"; the sync finds existing work items by it.")
					})
					ui.Fieldset(c, "Jira", func() {
						ui.Field(c, "Site URL", func() { ui.TextInput(c.Key("jiraurl"), &f.jiraURL).Placeholder("https://your-site.atlassian.net") })
						ui.Field(c, "Email", func() { ui.TextInput(c.Key("jiraemail"), &f.jiraEmail).Placeholder("you@company.com") })
						ui.Field(c, "API token", func() { ui.TextInput(c.Key("jiratoken"), &f.jiraToken).Password() }).
							Description("Stored in the macOS Keychain, never in the database.")
						ui.Field(c, "Extra JQL", func() { ui.TextInput(c.Key("jql"), &f.jqlExtra).Placeholder("issuetype in (Bug, Task)") }).
							Description("ANDed into every search.")
					})
					if a.LogPath != "" {
						ui.Fieldset(c, "Diagnostics", func() {
							ui.Field(c, "Log file", func() {
								ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
									ui.Text(c, a.LogPath).Font("monospace").FontSize(11).Selectable().Grow(1).MinWidth(0).SingleLine()
									svc := c.Services()
									ui.Button(c.Key("openlogs"), "Show in Finder").OnClick(func() { svc.OpenURL("file://" + filepath.Dir(a.LogPath)) })
									ui.Button(c.Key("copylog"), "Copy Path").OnClick(func() { svc.WriteClipboard(a.LogPath) })
								})
							}).Description("Every sync, HTTP failure and crash is logged here with its job, run and ticket; never tokens or PATs. Attach it when reporting a problem.")
						})
					}
				})
				ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
					if f.checking {
						ui.Spinner(c).Label("Checking Jira")
					}
					ui.Text(c, f.result).FontSize(12).TextColor(t.TextMuted).Grow(1).SingleLine()
					ui.Button(c.Key("testjira"), "Test Jira").Disabled(f.checking).OnClick(a.testJira)
					ui.PrimaryButton(c.Key("save"), "Save").Disabled(f.checking).OnClick(a.saveSettings)
				})
			})
		})
	})
}

// iconThumbs decodes each icon once; Bitmaps are costly to build.
var iconThumbs = sync.OnceValue(func() []*ui.Bitmap {
	bs := make([]*ui.Bitmap, len(appicon.Options))
	for i, o := range appicon.Options {
		bs[i], _ = ui.DecodeBitmap(o.PNG) // ponytail: embedded PNGs are known-good
	}
	return bs
})

func (a *App) appIconPicker(c *ui.Context) {
	t := c.Theme()
	icon := appicon.Get(a.store.Settings[setAppIcon]).ID
	ui.RadioGroup(c, func() {
		for i, o := range appicon.Options {
			ring := ui.RGBA(0, 0, 0, 0)
			if o.ID == icon {
				ring = t.Accent
			}
			ui.RadioBase(c.Key("icon-"+o.ID), &icon, o.ID).Label(o.Name).Column().Gap(6).AlignItems(ui.Center).
				Cursor(ui.CursorPointer).OnChange(func() { a.setAppIcon(icon) }).Children(func() {
				ui.Column(c).Padding(3).Radius(16).Border(2, ring).Children(func() {
					ui.Image(c, iconThumbs()[i]).Size(56, 56)
				})
				ui.Text(c, o.Name).FontSize(12).TextColor(t.TextMuted)
			})
		}
	}).Row().Gap(16).Label("App icon")
}

func (a *App) setAppIcon(id string) {
	a.store.SetSetting(setAppIcon, id)
	appicon.Apply(id)
}

func (a *App) saveSettings() {
	f := &a.settings
	a.store.SetSetting(setJiraURL, strings.TrimRight(strings.TrimSpace(f.jiraURL), "/"))
	a.store.SetSetting(setJiraEmail, strings.TrimSpace(f.jiraEmail))
	a.store.SetSetting(setJQLExtra, strings.TrimSpace(f.jqlExtra))
	a.store.SetSetting(setJiraKeyField, strings.TrimSpace(f.keyField))
	token := strings.TrimSpace(f.jiraToken)
	if token == a.jiraToken {
		a.notice = "Settings saved"
		return
	}
	var err error
	a.Async(func() {
		if token == "" {
			err = a.secrets.Jira.Delete()
		} else {
			err = a.secrets.Jira.Set(token)
		}
	}, func() {
		if err != nil {
			a.notice = "Couldn't save the Jira token to Keychain: " + err.Error()
			return
		}
		a.jiraToken = token
		a.notice = "Settings saved"
	})
}

// testJira checks what is typed, before it's saved.
func (a *App) testJira() {
	f := &a.settings
	conn := a.connection()
	conn.JiraURL, conn.JiraEmail, conn.JiraToken = strings.TrimRight(strings.TrimSpace(f.jiraURL), "/"), strings.TrimSpace(f.jiraEmail), strings.TrimSpace(f.jiraToken)
	f.checking, f.result = true, ""
	var name string
	var err error
	a.Async(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		name, err = a.engine.CheckJira(ctx, conn)
	}, func() {
		f.checking = false
		if err != nil {
			f.result = "Jira: " + err.Error()
		} else {
			f.result = "Jira OK — signed in as " + name
		}
	})
}

func (a *App) toggleRemember() {
	pat, remember := a.pat, a.remember
	var err error
	a.Async(func() { err = a.storePAT(pat, remember) }, func() {
		switch {
		case err != nil:
			a.remember = !remember
			a.notice = "Keychain: " + err.Error()
		case remember:
			a.notice = "PAT saved to Keychain"
		default:
			a.notice = "PAT removed from Keychain"
		}
	})
}
