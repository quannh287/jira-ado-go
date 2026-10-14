<p align="center"><img src="resources/icon.png" width="96" alt=""></p>

# jira-ado

A native desktop app that syncs Jira issues into Azure DevOps work items, one way (Jira → ADO). It's written in Go with [MyGo](https://github.com/egoist/mygo), and its UI is drawn natively — no webview. It ports the Next.js app's sync engine and flow.

## Features

- **Sync jobs**: each job pairs one Jira project with one ADO project. It runs on demand with **Sync Now**, and you can pause and resume it.
- **Incremental sync**: each job keeps a cursor, so a run only fetches issues updated since the last one. The first run imports the whole backlog. Progress is checkpointed after every issue, so a stopped run resumes where it left off.
- **Faithful mapping**:
  - Issues become Product Backlog Items; sub-tasks become Tasks, linked under their parent.
  - Priority, state, dates and time tracking are converted to the ADO equivalents.
  - Descriptions are converted from Jira's format to HTML.
  - Comments are copied, and editing one in Jira updates the same ADO comment.
  - Attachments are copied.
- **Sprints follow Jira**: an issue in an active Jira sprint goes to the current ADO sprint. Any other issue, including one taken out of its sprint, goes to the backlog (the sprint root path). Alternatively, every issue can go to one fixed iteration.
- **ADO stays in charge**: items that are Done in ADO are never overwritten; the change is added as a comment instead. On a job's first run, which imports the whole backlog, no comment is added. Estimates and dates already filled in ADO are kept, and the differences are commented.
- **Safe runs**: each sync first checks that its area and iteration paths exist in ADO, and stops before writing if one doesn't. **Dry Run** shows what a sync would send without writing anything. **Cancel** stops a run; the next sync resumes from the last checkpoint. **Retry failed** reruns only a run's failed tickets.
- **Mappings**: one shared user mapping for every job, and editable rules for issue type → work item type, status → state and priority. The defaults are the original app's rules.
- **Report**: for every run you can see what was written to each work item, with links to Jira and ADO. Every ADO API call is logged and can be expanded when you need to debug.
- **Logs**: all runs across jobs, with filters, JSON export and bulk delete.
- **Local and private**: jobs and history are stored in SQLite on your machine. The ADO PAT and the Jira token are stored in the OS keychain.

## Install

Download a build from **Actions** (the artifacts of the latest run) or from a release.

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

CI (`.github/workflows/build.yml`) runs tests, then builds macOS, Windows and Linux on every push. To publish a release, set `version` in `mygo.json`, then push a matching tag (`git tag v0.2.0 && git push origin v0.2.0`). CI creates a draft release with the apps attached; publish it on GitHub.
