import AppKit
import Observation
import UserNotifications

enum Page: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", jobs = "Sync Jobs", logs = "Logs", mappings = "Mappings", settings = "Settings"
    var id: Self { self }
    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .jobs: "arrow.triangle.2.circlepath"
        case .logs: "list.bullet"
        case .mappings: "link"
        case .settings: "gearshape"
        }
    }
}

/// Pages pushed on top of a section. A report opens on runID, nil meaning the live run (or the newest).
enum Route: Hashable {
    case job(Int)
    case edit(Int, step: Int)
    case create
    case report(Int, runID: Int?)
}

enum NotifyMode: String, CaseIterable { case all, failures, off }

struct AppIconOption: Identifiable {
    let id: String, name: String
    var image: NSImage? { NSImage(named: "icon-\(id)") }
    static let all = [AppIconOption(id: "merge", name: "Merge"), AppIconOption(id: "bridge", name: "Bridge"), AppIconOption(id: "lanes", name: "Lane change")]
    static let defaultID = "bridge"  // the packaged icon
    static func get(_ id: String?) -> AppIconOption { all.first { $0.id == id } ?? all[1] }
}

/// What Jira and ADO offer as mapping values, loaded once per launch.
struct CatalogState {
    var cat = Catalog()
    var loading = false
    var tried = false
    var error = ""
}

/// Shows desktop notifications; the app uses UserNotifier, tests record them.
protocol Notifier {
    func notify(id: String, title: String, subtitle: String, body: String)
}

/// The app's state and actions; views rebuild from it. Everything runs on the main actor.
@Observable
final class AppModel {
    static let shared = AppModel.launch()
    /// A first run imports the whole backlog; checkpoints make a run stopped by this resumable.
    static let syncTimeout: TimeInterval = 3600
    static let testNotificationID = "test"

    let store: Store
    let engine: SyncEngine
    @ObservationIgnored let secrets: Secrets
    @ObservationIgnored let notifier: Notifier
    /// Shows the number of jobs whose last run didn't fully succeed (the Dock badge).
    @ObservationIgnored var badge: (Int) -> Void = { n in NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil }
    @ObservationIgnored var now: () -> Date = Date.init

    var section: Page = .dashboard
    var path: [Route] = []
    var paletteOpen = false
    var notice: String?

    /// The keychain is read off the main actor at launch; until then neither login nor the app shows.
    var secretsLoaded = false
    // ponytail: a saved PAT is trusted at launch; sign out when the real engine gets a 401
    var pat = ""
    var remember = false  // the PAT is kept in the Keychain across launches
    var jiraToken = ""
    var loginError = ""

    private(set) var live: [Int: SyncProgress] = [:]
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var timedOut: Set<Int> = []
    private(set) var running: Set<Int> = []
    var catalog = CatalogState()

    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(store: Store, engine: SyncEngine, secrets: Secrets, notifier: Notifier) {
        self.store = store
        self.engine = engine
        self.secrets = secrets
        self.notifier = notifier
        store.onSaveError = { [weak self] in self?.show("Couldn't save: " + describe($0)) }
    }

    /// How this process runs: unit tests and UI tests get an in-memory store, the fake engine and no Keychain;
    /// JIRA_ADO_DEMO=1 uses the fake engine on the real database.
    static func launch(_ env: [String: String] = ProcessInfo.processInfo.environment,
                       _ args: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        if env["XCTestConfigurationFilePath"] != nil {
            return AppModel(store: Store(), engine: FakeEngine(delay: 0), secrets: .memory(), notifier: SilentNotifier())
        }
        if args.contains(LaunchArgument.uiTesting) {
            let store = Store(), fake = FakeEngine(delay: 0.3)
            let pat = args.contains(LaunchArgument.signedIn) ? String(repeating: "x", count: 24) : ""
            if args.contains(LaunchArgument.signedIn) {
                store.setSetting(Setting.adoOrg, "demo-org")
                store.setSetting(Setting.adoUser, "UI Tester")
            }
            if !args.contains(LaunchArgument.empty) { Task { await FakeEngine(delay: 0).seed(store) } }
            return AppModel(store: store, engine: fake, secrets: .memory(pat: pat), notifier: SilentNotifier())
        }
        AppLog.setup()
        let demo = env["JIRA_ADO_DEMO"] == "1"
        AppLog.info("app start", ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev", "demo": demo])
        let store: Store
        var openError: String?
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("jira-ado")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try Store(path: dir.appendingPathComponent("jira-ado.db").path)
            AppLog.info("database open", ["path": dir.path, "jobs": store.jobs.count, "runs": store.runs.count])
        } catch {
            // Running without saving beats not running; the notice says so.
            AppLog.error("open database", ["err": describe(error)])
            openError = "Couldn't open the database, nothing will be saved: " + describe(error)
            store = Store()
        }
        let model = AppModel(store: store, engine: demo ? FakeEngine(delay: 1.5) : Syncer(state: store), secrets: .keychain, notifier: UserNotifier())
        if let openError { model.show(openError) }
        if demo && store.jobs.isEmpty { Task { await FakeEngine(delay: 0).seed(store) } }
        return model
    }

    /// Called once the app has launched: Dock icon, secrets, scheduler.
    func start() {
        applyAppIcon()
        applyActivationPolicy()
        Task {
            await loadSecrets()
            tick()
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.tick()
            }
        }
    }

    /// Reads the PAT and the Jira token off the main actor: a Keychain prompt may block.
    func loadSecrets() async {
        let s = secrets
        let pat = await Task.detached { Result { try s.pat.get() } }.value
        let jira = await Task.detached { Result { try s.jira.get() } }.value
        switch pat {
        case .success(let p): (self.pat, remember) = (p, !p.isEmpty)
        case .failure(let e): loginError = "Couldn't read the saved PAT from Keychain: " + describe(e)
        }
        switch jira {
        case .success(let t): jiraToken = t
        case .failure(let e): show("Couldn't read the Jira token from Keychain: " + describe(e))
        }
        secretsLoaded = true
    }

    func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }

    func setting(_ key: String) -> String { store.settings[key] ?? "" }

    // MARK: Navigation

    func open(_ s: Page, _ routes: [Route] = []) {
        section = s
        path = routes
    }

    func openJob(_ id: Int) { open(.jobs, [.job(id)]) }

    func openReport(_ job: Int, run: Int?) { open(.jobs, [.job(job), .report(job, runID: run)]) }

    // MARK: Sign-in and secrets

    func signIn(org: String, pat: String, remember: Bool) async {
        let org = org.trimmingCharacters(in: .whitespaces), pat = pat.trimmingCharacters(in: .whitespaces)
        loginError = ""
        let name: String
        do { name = try await engine.validatePAT(org: org, pat: pat) } catch {
            AppLog.warn("ADO sign-in failed", ["org": org, "err": describe(error)])  // never the PAT
            loginError = describe(error)
            return
        }
        let saved = await storePAT(pat, remember: remember)
        if let saved {
            AppLog.error("save PAT to keychain", ["err": saved])
            show("Signed in for this session only: " + saved)
        }
        AppLog.info("ADO sign-in", ["org": org, "user": name, "remember": remember])
        self.pat = pat
        self.remember = remember && saved == nil
        store.setSetting(Setting.adoOrg, org)
        store.setSetting(Setting.adoUser, name)
        open(.dashboard)
        tick()
    }

    /// Saves or forgets the PAT in the Keychain; returns the error message, if any.
    private func storePAT(_ pat: String, remember: Bool) async -> String? {
        let s = secrets.pat
        return await Task.detached { () -> String? in
            do {
                if remember { try s.set(pat) } else { try s.delete() }
                return nil
            } catch { return describe(error) }
        }.value
    }

    func toggleRemember(_ on: Bool) async {
        remember = on
        if let err = await storePAT(pat, remember: on) {
            remember = !on
            show("Keychain: " + err)
        } else {
            show(on ? "PAT saved to Keychain" : "PAT removed from Keychain")
        }
    }

    func logout() async {
        if let err = await storePAT("", remember: false) { show("Couldn't remove the PAT from Keychain: " + err) }
        pat = ""
        remember = false
        open(.dashboard)
    }

    func saveSettings(jiraURL: String, email: String, jql: String, keyField: String, token: String) async {
        store.setSetting(Setting.jiraURL, trimSlash(jiraURL.trimmingCharacters(in: .whitespaces)))
        store.setSetting(Setting.jiraEmail, email.trimmingCharacters(in: .whitespaces))
        store.setSetting(Setting.jqlExtra, jql.trimmingCharacters(in: .whitespaces))
        store.setSetting(Setting.jiraKeyField, keyField.trimmingCharacters(in: .whitespaces))
        let token = token.trimmingCharacters(in: .whitespaces)
        if token != jiraToken {
            let s = secrets.jira
            let err = await Task.detached { () -> String? in
                do {
                    if token.isEmpty { try s.delete() } else { try s.set(token) }
                    return nil
                } catch { return describe(error) }
            }.value
            if let err { return show("Couldn't save the Jira token to Keychain: " + err) }
            jiraToken = token
        }
        show("Settings saved")
    }

    /// A snapshot of settings and secrets for one run; an incomplete one comes back as a failed run naming what's missing.
    func connection() -> Connection {
        Connection(adoOrg: setting(Setting.adoOrg), pat: pat, jiraURL: setting(Setting.jiraURL), jiraEmail: setting(Setting.jiraEmail),
                   jiraToken: jiraToken, jqlExtra: setting(Setting.jqlExtra), jiraKeyField: setting(Setting.jiraKeyField), rules: store.rules)
    }

    /// The shared user mapping goes after the job's own, so a job-specific entry wins.
    func effectiveJob(_ j: Job) -> Job {
        var j = j
        j.filters.users += store.sharedUsers
        return j
    }

    // MARK: Runs

    @discardableResult func syncNow(_ id: Int) -> Task<Void, Never>? { startRun(id, RunOptions()) }

    /// Reads Jira and ADO like a sync but writes nothing; its report shows what a sync would send.
    @discardableResult func dryRun(_ id: Int) -> Task<Void, Never>? { startRun(id, RunOptions(dryRun: true)) }

    /// Reruns only the failed tickets of r, without touching the cursor.
    @discardableResult func retryFailed(_ r: Run) -> Task<Void, Never>? {
        r.failedKeys.isEmpty ? nil : startRun(r.jobID, RunOptions(keys: r.failedKeys))
    }

    /// Stops a job's run at the next issue, with the cursor at its last checkpoint.
    func cancelRun(_ id: Int) {
        guard let t = tasks[id] else { return }
        t.cancel()
        store.log(id, "Cancel requested")
    }

    /// The run's task, or nil when the job can't start (missing, paused or already running).
    private func startRun(_ id: Int, _ options: RunOptions) -> Task<Void, Never>? {
        guard let j = store.job(id), j.status == .active, !running.contains(id) else { return nil }
        let conn = connection(), job = effectiveJob(j)
        let label = options.dryRun ? "Dry run" : options.keys.isEmpty ? "Sync" : "Retry of \(options.keys.count) failed tickets"
        running.insert(id)
        live[id] = SyncProgress(run: Run(jobID: id, started: now(), kind: options.dryRun ? .dryRun : .sync))
        store.log(id, label + " started")
        var opts = options
        opts.onProgress = { [weak self] p in
            if self?.running.contains(id) == true { self?.live[id] = p }  // a late snapshot must not resurrect the live run
        }
        let task = Task { [engine] in
            var run = await engine.sync(conn, job, opts)
            if timedOut.remove(id) != nil && run.error == "Cancelled" { run.error = "Stopped: the run took longer than its time limit" }
            finish(id, job, label, run)
        }
        tasks[id] = task
        Task {
            try? await Task.sleep(for: .seconds(Self.syncTimeout))
            if running.contains(id) && tasks[id] == task {
                timedOut.insert(id)
                task.cancel()
            }
        }
        return task
    }

    private func finish(_ id: Int, _ job: Job, _ label: String, _ run: Run) {
        running.remove(id)
        live[id] = nil
        tasks[id] = nil
        guard store.job(id) != nil else { return }  // deleted while syncing
        var run = run
        run.id = store.addRun(run)
        notifyRun(job, run)
        // Someone watching the live run now sees the saved one in its place.
        if let i = path.firstIndex(of: .report(id, runID: nil)) { path[i] = .report(id, runID: run.id) }
        let summary = run.error.isEmpty ? fmtRunSummary(run) : "failed: " + run.error
        store.log(id, "\(label) \(summary)")
        show("\(job.name): \(summary)")
        updateBadge()
    }

    /// Starts every active Scheduler job whose interval has passed since its last run (or its creation).
    func tick() {
        updateBadge()
        guard !pat.isEmpty else { return }  // signed out: every run would fail on the missing PAT
        let now = now()
        for j in store.jobs where j.type == .scheduler && j.status == .active && !running.contains(j.id) {
            let last = store.lastRun(j.id)?.started ?? j.created
            if now.timeIntervalSince(last) >= j.filters.every { syncNow(j.id) }
        }
    }

    /// The Dock badge counts jobs whose last run didn't fully succeed.
    func updateBadge() {
        badge(store.jobs.filter { store.lastRun($0.id).map { $0.status != .success } ?? false }.count)
    }

    // MARK: Menu bar

    /// The menu bar icon replaces the Dock icon; on by default.
    var showsMenuBar: Bool { setting(Setting.menuBar) != "off" }

    func setMenuBar(_ on: Bool) {
        store.setSetting(Setting.menuBar, on ? "on" : "off")
        applyActivationPolicy()
    }

    /// A menu bar app has no Dock icon and isn't in ⌘Tab; turning it off brings both back.
    private func applyActivationPolicy() {
        guard let app = NSApp else { return }
        app.setActivationPolicy(showsMenuBar ? .accessory : .regular)
        app.activate()
    }

    /// What the menu bar icon says: syncing, failing jobs, or all fine.
    struct MenuStatus: Equatable {
        var symbol: String
        var title: String
        var failing = 0
    }

    var menuStatus: MenuStatus {
        if !running.isEmpty {
            let names = store.jobs.filter { running.contains($0.id) }.map(\.name)
            return MenuStatus(symbol: "arrow.triangle.2.circlepath", title: "Syncing " + names.joined(separator: ", "))
        }
        let failing = store.jobs.filter { store.lastRun($0.id).map { $0.status != .success } ?? false }.count
        if failing > 0 {
            return MenuStatus(symbol: "exclamationmark.triangle", title: failing == 1 ? "1 job failing" : "\(failing) jobs failing", failing: failing)
        }
        guard let last = store.runs.first(where: { $0.kind != .dryRun }) else { return MenuStatus(symbol: "checkmark.circle", title: "No runs yet") }
        return MenuStatus(symbol: "checkmark.circle", title: "Last run OK · " + ago(last.started, now()))
    }

    /// One line per job for the menu: its state now, or how its last run went.
    func menuLine(_ j: Job) -> String {
        if running.contains(j.id) { return "\(j.name) — " + (live[j.id].map(progressText) ?? "syncing") }
        if j.status == .paused { return "\(j.name) — paused" }
        guard let r = store.lastRun(j.id) else { return "\(j.name) — never run" }
        return "\(j.name) — \(r.status == .success ? "OK" : r.status.rawValue) \(ago(r.started, now()))"
    }

    // MARK: Notifications

    var notifyMode: NotifyMode { NotifyMode(rawValue: setting(Setting.notify)) ?? .all }

    /// Tells the user a run finished, unless the mode says otherwise; a click opens its report.
    private func notifyRun(_ job: Job, _ r: Run) {
        let failed = r.status != .success
        guard notifyMode == .all || (notifyMode == .failures && failed) else { return }
        let what = r.kind == .dryRun ? "Dry run" : r.kind == .retry ? "Retry" : "Sync"
        var subtitle = what + " finished", body = fmtRunCounts(r)
        if !r.error.isEmpty {
            (subtitle, body) = (what + " failed", r.error)
        } else if r.count(.failed) > 0 {
            subtitle = what + " finished with failures"
            let keys = r.failedKeys
            body += "\nFailed: " + keys.prefix(3).joined(separator: ", ") + (keys.count > 3 ? " +\(keys.count - 3)" : "")
        }
        notifier.notify(id: notificationID(job.id, r.id), title: job.name, subtitle: subtitle, body: body)
    }

    /// Shows what a clicked notification is about; a run deleted since lands on its job, anything else on the dashboard.
    func openNotification(_ id: String) {
        openMainWindow?()
        NSApp?.activate()
        if id == Self.testNotificationID { return open(.settings) }
        guard let (job, run) = parseNotificationID(id), store.job(job) != nil else { return open(.dashboard) }
        if store.run(run) != nil { openReport(job, run: run) } else { openJob(job) }
    }

    // MARK: Appearance

    func setAppIcon(_ id: String) {
        store.setSetting(Setting.appIcon, id)
        applyAppIcon()
    }

    /// The Dock icon while the app runs; Finder keeps the packaged one.
    private func applyAppIcon() {
        NSApp?.applicationIconImage = AppIconOption.get(store.settings[Setting.appIcon]).image
    }

    // MARK: Mappings

    /// Asks the engine for the choices of every project the jobs use.
    func loadCatalog() async {
        let jira = union([store.jobs.map(\.jiraKey)]), ado = union([store.jobs.map(\.adoProject)])
        catalog.tried = true
        catalog.error = ""
        guard !jira.isEmpty else {
            catalog.error = "Create a sync job first; the lists come from its Jira and ADO projects."
            return
        }
        catalog.loading = true
        let (cat, err) = await engine.catalog(connection(), jiraProjects: jira, adoProjects: ado)
        catalog.cat = cat
        catalog.error = err ?? ""
        catalog.loading = false
    }
}

/// Launch arguments the UI tests start the app with.
enum LaunchArgument {
    static let uiTesting = "-ui-testing"  // in-memory store, fake engine, demo jobs
    static let signedIn = "-signed-in"  // skip the login page
    static let empty = "-empty"  // no demo jobs
}

/// Notifications through Notification Center; the first one waits for the user's permission answer.
struct UserNotifier: Notifier {
    func notify(id: String, title: String, subtitle: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.subtitle = subtitle
        c.body = body
        c.threadIdentifier = "runs"
        let req = UNNotificationRequest(identifier: id, content: c, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
                    return AppLog.warn("notifications denied by the user")
                }
                try await center.add(req)
                AppLog.info("notification shown", ["id": id])
            } catch { AppLog.error("show notification", ["id": id, "err": describe(error)]) }
        }
    }
}

struct SilentNotifier: Notifier {
    func notify(id: String, title: String, subtitle: String, body: String) {}
}
