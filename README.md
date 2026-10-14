<p align="center"><img src="resources/icon.png" width="96" alt=""></p>

# jira-ado

A native desktop app that syncs Jira issues into Azure DevOps work items, one way (Jira → ADO). It's written in Go with [MyGo](https://github.com/egoist/mygo), and its UI is drawn natively — no webview. It ports the Next.js app's sync engine and flow.

## Features

### Set up once
- **Sign in with your ADO PAT.** It's kept in the macOS Keychain (or Windows Credential Manager), so you stay signed in. The Jira API token is stored there too, never in a file.
- **Create a sync job in 4 steps.** Pick the Jira project and the ADO project, choose which fields to copy (**Smart Defaults** picks them all), set filters, and review before saving.
- **Edit a job any time.** Change its fields, filters, area path or sprint settings with **Edit Job**, or jump straight to a step from the job's tabs.
- **Check before you sync.** **Check in ADO** confirms the area path and sprint exist, so a typo doesn't fail every ticket.

### What a sync does
- **Copies Jira issues into ADO work items.** Stories become Product Backlog Items, sub-tasks become Tasks linked under their parent. Title, description, state, priority, assignee, dates and time tracking come along.
- **Keeps comments and attachments in step.** New Jira comments are added, edited ones are updated in place, and attachments are copied.
- **Only touches what changed.** Each run picks up where the last one stopped. Work items that are already up to date aren't rewritten, so ADO gets no needless revisions or notifications.
- **Puts work in the right sprint.** An issue in the active Jira sprint goes to this week's ADO sprint. Anything else goes to the backlog, including issues taken out of a sprint.
- **Respects ADO.** A work item that is Done in ADO is never overwritten; the Jira change is left as a comment. Estimates and dates someone filled in ADO are kept, and differences are commented. Files attached in ADO are not removed.
- **Filters by person.** Sync only issues assigned to chosen people, and map Jira users to their ADO emails.

### Run it your way
- **Sync Now** for a real run, or **Dry Run** to see exactly what would be sent without changing anything in ADO.
- **Watch it live.** The report fills in ticket by ticket while the sync runs, with a progress bar.
- **Cancel** a run safely. The next sync continues from where it stopped.
- **Retry failed** reruns only the tickets that failed, without re-reading everything else.
- **Get notified** when a run ends, every time or only on failures. Click the notification to open that run's report.

### See what happened
- **Run report.** Created, updated, skipped and failed counts, then every ticket with what was written to ADO, with links to open it in Jira and in ADO. Sub-tasks are grouped under their parent.
- **Error details when you need them.** Each ticket's ADO requests and responses are one click away, folded by default.
- **Logs.** Every run of every job, filtered by job and status, exportable as JSON, deletable one by one or in bulk.
- **Diagnostic log file.** Errors and crashes are written to a log you can open from **Settings → Diagnostics**, so problems can be traced. It never contains tokens.

### Shared rules
- **Mappings page.** One list of Jira user → ADO email for every job, plus the rules for issue type → work item type, Jira status → ADO state and priority. Choose values from drop-downs loaded from your Jira and ADO projects.

### Feels native
- **macOS-style window**: a dark floating sidebar, light, dark or system theme for the content, and **⌘K** to jump to any page or job.
- **Pick the app icon** from three designs.
- **Your data stays on your machine** in a local database. It runs on macOS, Windows and Linux.

## Install

Download the latest build from the repository's **Releases** page.

| OS | File | Note |
|---|---|---|
| macOS (Apple Silicon + Intel) | `jira-ado <version>.dmg` | The app is signed ad hoc only: right-click → **Open** the first time, or run `xattr -dr com.apple.quarantine /Applications/jira-ado.app` |
| Windows | `jira-ado Setup <version> <arch>.exe` or `…-portable.zip` | The app is unsigned: in the SmartScreen warning, choose **More info → Run anyway** |
| Linux | `.deb` or `.tar.gz` + `install.sh` | Saving the PAT needs a Secret Service (gnome-keyring or KWallet) |

## First run

1. **Sign in**: enter your ADO organization (`dev.azure.com/<org>`) and a Personal Access Token with the **Work Items (Read & Write)** scope. Keep **Remember in Keychain** on to stay signed in.
2. **Settings**: enter your Jira site URL, email and an [API token](https://id.atlassian.com/manage-profile/security/api-tokens), then click **Test Jira**. The ADO field that stores the Jira key defaults to `Custom.JiraID`.
3. **New Sync Job** (⌘N): fill in the 4 steps — Basic, Field Mapping (start with **Smart Defaults**), Filters (user filter, user mapping, area path, iteration), Review. Change it later with **Edit Job**.
4. **Sync Now**, then open **View Report**.

## Development

Requires Go (see `go.mod`). The MyGo CLI is pinned as a Go tool, so you don't need Bun or npm.

```sh
go tool mygo dev                              # run with reload
JIRA_ADO_DEMO=1 go tool mygo dev              # fake engine + demo data, no Jira/ADO calls
CGO_ENABLED=0 go test ./...                   # tests
go tool mygo vet ./internal/app               # MyGo-specific checks
go tool mygo build -platform darwin/universal # DMG in build/
```

The architecture, conventions and pitfalls are documented in [CLAUDE.md](CLAUDE.md). The palette research is in [docs/design-system.md](docs/design-system.md).

## Importing from the Next.js app

`cmd/importmongo` copies jobs, cursors, comment mappings and run history from that app's MongoDB into this app's database. It reads MongoDB and never writes to it. Stop the app first.

```sh
node cmd/importmongo/export.mjs ~/path/to/nextjs-app /tmp/export
go run ./cmd/importmongo -export /tmp/export -db "<app data>/jira-ado.db" -dry-run
```

## Releases

CI (`.github/workflows/build.yml`) runs the tests on every push and pull request. Apps are built only for tags, or on demand with **Actions → Build → Run workflow**, whose artifacts you can download. To release, push a tag: `git tag v0.3.0 && git push origin v0.3.0`. CI builds the apps with the tag's version, publishes the release with them attached, and then commits that version to `mygo.json` on `main` (run `git pull` afterwards).
