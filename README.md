# jira-ado (Swift)

Native macOS (SwiftUI) one-way Jira → Azure DevOps sync tool; a port of the Go/MyGo app in `../jira-ado`.

## Layout

- `jira-ado-swift/App` — entry point, `AppDelegate` (background running, quit guard, notifications), `AppModel` (state + actions, injectable for tests)
- `Models` — jobs, runs, rules, connection, catalog
- `Persistence` — SQLite (`Database`, `Store`) and `LegacyImport` from the Go app's database
- `Networking` — `HTTPClient` (retries 429/5xx/network only), Jira and ADO clients
- `Sync` — `Syncer` (real engine), issue sync, ADF → HTML, `FakeEngine` (demo / tests)
- `Services` — Keychain, file log · `Support` — formatting, errors, preview data · `Views` — one file per page
- `jira-ado-swiftTests` — unit tests (Swift Testing) · `jira-ado-swiftUITests` — XCUITest

## Commands

- Build: `xcodebuild -project jira-ado-swift.xcodeproj -scheme jira-ado-swift build`
- All tests: `xcodebuild test -project jira-ado-swift.xcodeproj -scheme jira-ado-swift -destination 'platform=macOS'`
- Unit tests only: add `-only-testing:jira-ado-swiftTests`
- Demo data, no Jira/ADO calls: enable `JIRA_ADO_DEMO` in the scheme's Run environment
- UI tests launch the app with `-ui-testing` (in-memory store, fake engine, demo jobs) plus `-signed-in` / `-empty`

## Moving from the Go app

Settings → Data → **Import from Go App…**, then pick `~/Library/Application Support/jira-ado/jira-ado.db` (and `jira-ado Dev/jira-ado.db` for its comment links). Jobs, runs, cursor and settings come from the database that synced last; comment links from all. The PAT and Jira token are shared through the Keychain (same service and accounts).
