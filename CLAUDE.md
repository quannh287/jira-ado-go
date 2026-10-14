# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Stack

Native macOS app in Swift/SwiftUI (Xcode 26+, macOS 26 deployment target), no third-party dependencies. A one-way Jira→ADO sync tool, ported from the Go/MyGo app that lived here until v0.2.4 (git history), itself a port of the Next.js app at `~/Development/OTHERS/jira-ado` (engine: `app/api/sync/jobs/[id]/run/route.ts`).

## Commands

- `xcodebuild -project jira-ado-swift.xcodeproj -scheme jira-ado-swift build` — build (product `jira-ado.app`, module `jira_ado`)
- `xcodebuild test -project jira-ado-swift.xcodeproj -scheme jira-ado-swift -destination 'platform=macOS'` — unit + UI tests
- add `-only-testing:jira-ado-swiftTests` (unit) or `-only-testing:jira-ado-swiftTests/<Suite>/<test>()` (quote it in zsh)
- `JIRA_ADO_DEMO=1` (scheme Run environment, off by default) — fake engine on the real database, demo jobs when empty

## Project

- `jira-ado-swift.xcodeproj` uses file-system synchronized groups (objectVersion 90): new files in `jira-ado-swift/`, `jira-ado-swiftTests/`, `jira-ado-swiftUITests/` join their target without editing the pbxproj. The shared scheme `xcshareddata/xcschemes/jira-ado-swift.xcscheme` runs both test bundles.
- Build settings: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency, Swift 5 mode, app sandbox with outgoing network and user-selected read/write files, bundle ID `com.example.jiraado` (same as the Go app, so it replaces it).
- `design/logo` holds the icon sources; `Assets.xcassets` has `AppIcon` and the three Dock icons `icon-merge|bridge|lanes`. `docs/design-system.md` is the palette research.

## Architecture (`jira-ado-swift/`)

- **Concurrency**: everything is main-actor by default. The engine is `async` on the main actor; its waits are `await URLSession`, so the UI never blocks and progress callbacks land on main directly. Keychain calls (`SecretStore`, `nonisolated`) go through `Task.detached`: they can block on a prompt. Cancel = `Task.cancel()`; the 1h limit cancels and rewrites "Cancelled" as the time-limit message.
- **Models**: `Job`/`Filters` (paths, `sprintNumber`), `Run`/`Ticket`/`APICall`, `RunOptions`/`SyncProgress`, `Connection.missing`, `Catalog`, `Rules` (`orDefault`, case-insensitive `lookup`), `Field.supported`.
- **Persistence**: `Database` is a thin SQLite3 wrapper (`readOnly` for foreign files). `Store` (`@Observable`) keeps jobs/runs/settings in memory and writes each mutation through in one transaction; failures go to `onSaveError`. `Store()` is the DB-less variant for tests and UI tests. Schema changes are appended to `Store.migrations` (`user_version`); never edit a shipped step. `Store` is also the `SyncState` (cursor, comment mappings); `ReadOnlyState` wraps it for dry runs.
- **LegacyImport**: reads the Go app's database (schema v1–v4, JSON with Go field names) read-only; `Store.importLegacy` takes jobs/runs/cursor/settings from the snapshot that synced last and comment links from all, renumbers IDs, one transaction. The sandbox only lets the app read files the user picks (Settings → Data).
- **Networking**: `HTTPClient.send` retries 429/5xx/network 3× (0.5/1/2s), never other 4xx; 30s timeout, 32MB cap, ephemeral session without cookies. `HTTPClient.session`/`retryDelay` are swapped in tests. `JiraClient`/`ADOClient` parse with `JSONSerialization` (dynamic fields, Sprint custom field); `ADOClient.onCall` records every request as the ticket's `APICall`s; WIQL values are escaped.
- **Sync**: `SyncEngine` is the only boundary to Jira/ADO (`Syncer` real, `FakeEngine` demo/tests). `Syncer` ports `runSync`: preflight (area/iteration paths, Sprint field) → cursor JQL in the Jira account's zone (unknown zone → 12h back) → assignee refetch → sub-task backfill → parents first → details 50 per search → per issue: `findID` cache, create-then-move state, Done = comment only (none on a first run), Removed reset, preserved fields + conflict comment, `changedOps` skips unchanged writes, attachments only when Jira has some, comments add/patch → `Checkpoint` watermark per issue. `JiraAPI`/`ADOAPI` protocols let tests use fakes; `DryADO` records writes as `notSent`.
- **App**: `AppModel` holds UI state and actions (`startRun` returns the run's `Task`, `tick` scheduler, badge, notifications through `Notifier`, `openNotification` routing, `loadSecrets`, sign-in, settings, catalog). `AppModel.launch` picks the mode: unit-test host → in-memory + fake; `-ui-testing` (+ `-signed-in`, `-empty`) → in-memory + fake + demo jobs; otherwise the real DB and Keychain. `AppDelegate`: closing the window keeps the app running, Dock click reopens, ⌘Q asks while runs are in flight, notification clicks route to the report.
- **Views**: one file per page (`RootView` with sidebar/toolbar/palette/toast, `Dashboard`, `JobView`, `JobEditorView` with `Job.wizardError`, `ReportView`, `LogsView`, `MappingsView` with `MappingsForm`, `SettingsView`); `Widgets.swift` for `Pill`, `StatCard`, `KV`, `Mono`. Navigation = sidebar `Page` + `NavigationStack` path of `Route`. Every view has `#Preview`s over `PreviewData.model(...)`.
- **Logging**: `AppLog` writes `~/Library/Logs/jira-ado.log` (in the container; rotated past 10MB) and the unified log. Log URLs, IDs, statuses, elapsed, retries — never bodies, headers, PATs or tokens.

## Tests

- Unit (`jira-ado-swiftTests`, Swift Testing, `@testable import jira_ado`): syncer flows with `FakeJira`/`FakeADO`, store/SQLite, network via `StubProtocol` (`NetworkTests` is `.serialized` because it swaps the shared session), models, formatting, `AppModel` with `ScriptedEngine`/`RecordingNotifier`, legacy import from a synthetic Go v4 database.
- UI (`jira-ado-swiftUITests`, XCUITest): on macOS SwiftUI `Text` is a static text whose **value** holds the string and `Table` is an **outline**; match buttons by label (toolbar buttons have no title identifier); inputs carry `accessibilityIdentifier`s (`login.*`, `job.*`, `settings.*`, `palette.search`); a radio button's selection is its `value`. Failures print the accessibility tree.

## Releases

`.github/workflows/build.yml`: unit tests on every push/PR; a `v*` tag builds a universal, ad-hoc signed `jira-ado.app` with the tag as `MARKETING_VERSION`, publishes `jira-ado-<version>.dmg`, then bumps `MARKETING_VERSION` on main.
