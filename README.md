<p align="center"><img src="design/logo/icon-1024.png" width="96" alt=""></p>

# jira-ado

A native macOS app that syncs Jira issues into Azure DevOps work items, one way (Jira → ADO). It's written in Swift with SwiftUI. Up to v0.2.4 it was a Go/MyGo app (see the git history).

## Features

### Set up once
- **Sign in with your ADO PAT.** It's kept in the macOS Keychain, so you stay signed in. The Jira API token is stored there too, never in a file.
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
- **Scheduler jobs** run on their interval, also with the window closed; ⌘Q asks first while a sync is running.
- **Watch it live.** The report fills in ticket by ticket while the sync runs, with a progress bar.
- **Cancel** a run safely. The next sync continues from where it stopped.
- **Retry failed** reruns only the tickets that failed, without re-reading everything else.
- **Get notified** when a run ends, every time or only on failures. Click the notification to open that run's report.

### See what happened
- **Run report.** Created, updated, skipped and failed counts, then every ticket with what was written to ADO, with links to open it in Jira and in ADO. Sub-tasks are grouped under their parent.
- **Logs.** Every run of every job, filtered by job and status, exportable as JSON, deletable one by one or in bulk.
- **Diagnostic log file**, opened from **Settings → Diagnostics**. It never contains tokens.

### Shared rules
- **Mappings page.** One list of Jira user → ADO email for every job, plus the rules for issue type → work item type, Jira status → ADO state and priority, with drop-downs loaded from your Jira and ADO projects.

## Install

Download `jira-ado-<version>.dmg` (Apple Silicon + Intel) from the repository's **Releases** page. The app is signed ad hoc only: right-click → **Open** the first time, or run `xattr -dr com.apple.quarantine /Applications/jira-ado.app`.

### Moving from the Go app
The Swift app has the same bundle ID, so it replaces `/Applications/jira-ado.app`. Your PAT and Jira token carry over through the Keychain (macOS asks once). For jobs, history and settings: **Settings → Data → Import from Go App…**, then pick `~/Library/Application Support/jira-ado/jira-ado.db`, and `jira-ado Dev/jira-ado.db` too if you ran dev builds: its comment links keep comments from being posted twice.

## First run

1. **Sign in**: enter your ADO organization (`dev.azure.com/<org>`) and a Personal Access Token with the **Work Items (Read & Write)** scope.
2. **Settings**: enter your Jira site URL, email and an [API token](https://id.atlassian.com/manage-profile/security/api-tokens), then click **Test Jira**.
3. **New Sync Job** (⌘N), then **Sync Now** and **View Report**.

## Development

Requires Xcode 26 or later. Conventions and architecture are in [CLAUDE.md](CLAUDE.md).

- Build: `xcodebuild -project jira-ado-swift.xcodeproj -scheme jira-ado-swift build`
- All tests: `xcodebuild test -project jira-ado-swift.xcodeproj -scheme jira-ado-swift -destination 'platform=macOS'`
- Unit tests only: add `-only-testing:jira-ado-swiftTests`
- Demo data, no Jira/ADO calls: enable `JIRA_ADO_DEMO` in the scheme's Run environment

## Releases

CI (`.github/workflows/build.yml`) runs the unit tests on every push and pull request. To release, push a tag: `git tag v0.3.0 && git push origin v0.3.0`. CI builds a universal `jira-ado.app` with the tag's version, publishes the release with `jira-ado-<version>.dmg`, then commits that version to `MARKETING_VERSION` on `main` (run `git pull` afterwards). **Actions → Build → Run workflow** builds on demand.
