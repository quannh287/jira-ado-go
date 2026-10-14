package app

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
)

type loginForm struct {
	org      string
	pat      string
	err      string
	checking bool
	remember bool
}

func (a *App) loginPage(c *ui.Context) {
	t := c.Theme()
	f := &a.login
	ui.Column(c).Fill().Background(t.Background).Children(func() {
		ui.Box(c).Height(TitleBarHeight).Shrink(0).DragWindow()
		ui.Column(c).Grow(1).Center().Children(func() {
			ui.Column(c).Width(380).Gap(16).Padding(28).Radius(12).Background(t.Surface).Border(1, t.Border).Children(func() {
				ui.Icon(c, iconSync).Size(28, 28).TextColor(t.Accent)
				ui.Column(c).Gap(4).Children(func() {
					ui.Text(c, "Sign in to Azure DevOps").FontSize(18).Bold()
					ui.Text(c, "Paste a Personal Access Token with Work Items (Read & Write) scope.").
						FontSize(12).TextColor(t.TextMuted)
				})
				var in ui.Element
				ui.Field(c, "Organization", func() {
					ui.TextInput(c.Key("org"), &f.org).Placeholder("my-org").Disabled(f.checking)
				}).Description("dev.azure.com/<organization>")
				ui.Field(c, "Personal Access Token", func() {
					in = ui.TextInput(c.Key("pat"), &f.pat).Password().Placeholder("ADO PAT").AutoFocus().Disabled(f.checking)
				}).Error(f.err)
				ui.Checkbox(c.Key("remember"), &f.remember, "Remember in Keychain").Disabled(f.checking).
					Tooltip("Off: you sign in again every time the app starts")
				ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
					if f.checking {
						ui.Spinner(c).Label("Checking token")
						ui.Text(c, "Checking with ADO…").FontSize(12).TextColor(t.TextMuted)
					}
					ui.Spacer(c)
					btn := ui.PrimaryButton(c.Key("signin"), "Sign In").Disabled(f.checking || strings.TrimSpace(f.pat) == "" || strings.TrimSpace(f.org) == "")
					if in.Submitted() || btn.Clicked() {
						a.signIn()
					}
				})
			})
		})
	})
}

func (a *App) signIn() {
	f := &a.login
	pat, org := strings.TrimSpace(f.pat), strings.TrimSpace(f.org)
	if pat == "" || org == "" || f.checking {
		return
	}
	f.checking, f.err = true, ""
	remember := f.remember
	var err, saveErr error
	var name string
	a.Async(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if name, err = a.engine.ValidatePAT(ctx, org, pat); err == nil {
			saveErr = a.storePAT(pat, remember)
		}
	}, func() {
		f.checking = false
		if err != nil {
			slog.Warn("ADO sign-in failed", "org", org, "err", err) // never the PAT
			f.err = err.Error()
			return
		}
		slog.Info("ADO sign-in", "org", org, "user", name, "remember", remember)
		if saveErr != nil {
			slog.Error("save PAT to keychain", "err", saveErr)
			a.notice = "Signed in for this session only: " + saveErr.Error()
		}
		a.pat, f.pat = pat, ""
		a.store.SetSetting(setADOOrg, org)
		a.store.SetSetting(setADOUser, name)
		a.remember = remember && saveErr == nil
		a.router.Replace("/")
	})
}

// storePAT saves or forgets the PAT in the keychain; it can block on a Keychain prompt, so call it off the UI thread.
func (a *App) storePAT(pat string, remember bool) error {
	if remember {
		return a.secrets.PAT.Set(pat)
	}
	return a.secrets.PAT.Delete()
}
