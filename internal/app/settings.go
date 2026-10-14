package app

import (
	"context"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

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
