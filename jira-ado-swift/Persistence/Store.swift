import Foundation
import Observation

/// Jobs and runs (newest first) in memory for the UI; with a database every change is written through to it.
// ponytail: loads every run at startup, page runs from SQL when history gets large
@Observable
final class Store {
    private(set) var jobs: [Job] = []
    private(set) var runs: [Run] = []
    /// App-wide key/values (ADO org, Jira URL…); secrets go to the keychain, never here.
    private(set) var settings: [String: String] = [:]
    /// Reports a failed write; the change stays in memory.
    @ObservationIgnored var onSaveError: ((Error) -> Void)?

    @ObservationIgnored private let db: Database?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var nextJob = 0
    @ObservationIgnored private var nextRun = 0
    // State when there is no database.
    @ObservationIgnored private var memCursors: [Int: String] = [:]
    @ObservationIgnored private var memComments: [Int: [String: CommentMapping]] = [:]

    // migrations[i] moves the schema from user_version i to i+1; append, never edit a shipped step.
    private static let migrations: [[String]] = [[
        """
        CREATE TABLE jobs (id INTEGER PRIMARY KEY, name TEXT NOT NULL, jira_key TEXT NOT NULL, ado_project TEXT NOT NULL,
            type TEXT NOT NULL, status TEXT NOT NULL, created INTEGER NOT NULL, mappings TEXT NOT NULL, filters TEXT NOT NULL)
        """,
        """
        CREATE TABLE job_activity (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
            at INTEGER NOT NULL, text TEXT NOT NULL)
        """,
        """
        CREATE TABLE runs (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
            started INTEGER NOT NULL, duration_ms INTEGER NOT NULL, since TEXT NOT NULL, error TEXT NOT NULL,
            kind TEXT NOT NULL, tickets TEXT NOT NULL)
        """,
        "CREATE INDEX runs_job ON runs(job_id)",
        "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        // Cursor per job: the sync only asks Jira for issues updated since it.
        "CREATE TABLE sync_state (job_id INTEGER PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE, cursor TEXT NOT NULL)",
        """
        CREATE TABLE comment_mappings (ado_work_item_id INTEGER NOT NULL, jira_comment_id TEXT NOT NULL,
            ado_comment_id INTEGER NOT NULL, jira_updated TEXT NOT NULL, PRIMARY KEY (ado_work_item_id, jira_comment_id))
        """,
    ]]

    /// In-memory store, for tests and demos.
    init(now: @escaping () -> Date = Date.init) {
        db = nil
        self.now = now
    }

    /// Loads the SQLite database at path, creating it when missing.
    init(path: String, now: @escaping () -> Date = Date.init) throws {
        db = try Database(path: path)
        self.now = now
        try migrate()
        try load()
    }

    private func migrate() throws {
        guard let db else { return }
        let version = Int(try db.query("PRAGMA user_version").first?.first as? Int64 ?? 0)
        for v in version..<max(version, Self.migrations.count) {
            try db.transaction(Self.migrations[v].map { ($0, []) } + [("PRAGMA user_version = \(v + 1)", [])])
        }
    }

    private func load() throws {
        guard let db else { return }
        for r in try db.query("SELECT key, value FROM settings") { settings[str(r[0])] = str(r[1]) }
        for r in try db.query("SELECT id, name, jira_key, ado_project, type, status, created, mappings, filters FROM jobs ORDER BY id") {
            var j = Job(id: int(r[0]), name: str(r[1]), jiraKey: str(r[2]), adoProject: str(r[3]),
                        type: SyncType(rawValue: str(r[4])) ?? .manual, status: JobStatus(rawValue: str(r[5])) ?? .active,
                        created: date(r[6]))
            j.mappings = try decode(str(r[7]))
            j.filters = try decode(str(r[8]))
            jobs.append(j)
            nextJob = max(nextJob, j.id)
        }
        for r in try db.query("SELECT job_id, at, text FROM job_activity ORDER BY id") {
            if let i = jobs.firstIndex(where: { $0.id == int(r[0]) }) {
                jobs[i].activity.append(Activity(at: date(r[1]), text: str(r[2])))
            }
        }
        for r in try db.query("SELECT id, job_id, started, duration_ms, since, error, kind, tickets FROM runs ORDER BY id DESC") {
            let run = Run(id: int(r[0]), jobID: int(r[1]), started: date(r[2]), duration: Double(int(r[3])) / 1000,
                          since: str(r[4]), error: str(r[5]), kind: RunKind(rawValue: str(r[6])) ?? .sync,
                          tickets: try decode(str(r[7])))
            runs.append(run)
            nextRun = max(nextRun, run.id)
        }
    }

    /// Writes atomically; memory is already updated, so a failure is only reported.
    private func write(_ stmts: Database.Statement...) { write(contentsOf: stmts) }

    private func write(contentsOf stmts: [Database.Statement]) {
        guard let db else { return }
        do { try db.transaction(stmts) } catch {
            AppLog.error("store write failed", ["statements": stmts.count, "err": describe(error)])
            onSaveError?(error)
        }
    }

    // MARK: Jobs

    func job(_ id: Int) -> Job? { jobs.first { $0.id == id } }

    @discardableResult
    func addJob(_ new: Job) -> Int {
        nextJob += 1
        var j = new
        j.id = nextJob
        j.status = .active
        j.created = now()
        j.activity = [Activity(at: j.created, text: "Job created")]
        jobs.append(j)
        write(("INSERT INTO jobs (id, name, jira_key, ado_project, type, status, created, mappings, filters) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [j.id, j.name, j.jiraKey, j.adoProject, j.type.rawValue, j.status.rawValue, ms(j.created), encode(j.mappings), encode(j.filters)]),
              activityStmt(j.id, j.activity[0]))
        return j.id
    }

    /// Saves a job's editable settings; ID, Jira key, status, creation and activity stay the store's.
    func updateJob(_ j: Job) {
        guard let i = jobs.firstIndex(where: { $0.id == j.id }) else { return }
        jobs[i].name = j.name
        jobs[i].adoProject = j.adoProject
        jobs[i].type = j.type
        jobs[i].mappings = j.mappings
        jobs[i].filters = j.filters
        let a = Activity(at: now(), text: "Job settings changed")
        jobs[i].activity.append(a)
        let cur = jobs[i]
        write(("UPDATE jobs SET name = ?, ado_project = ?, type = ?, mappings = ?, filters = ? WHERE id = ?",
               [cur.name, cur.adoProject, cur.type.rawValue, encode(cur.mappings), encode(cur.filters), cur.id]),
              activityStmt(cur.id, a))
    }

    func deleteJob(_ id: Int) {
        jobs.removeAll { $0.id == id }
        runs.removeAll { $0.jobID == id }
        write(("DELETE FROM jobs WHERE id = ?", [id]))  // cascades to activity, runs and state
    }

    func setStatus(_ id: Int, _ st: JobStatus) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status != st else { return }
        jobs[i].status = st
        let a = Activity(at: now(), text: st == .active ? "Job resumed" : "Job paused")
        jobs[i].activity.append(a)
        write(("UPDATE jobs SET status = ? WHERE id = ?", [st.rawValue, id]), activityStmt(id, a))
    }

    func log(_ id: Int, _ text: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let a = Activity(at: now(), text: text)
        jobs[i].activity.append(a)
        write(activityStmt(id, a))
    }

    private func activityStmt(_ id: Int, _ a: Activity) -> Database.Statement {
        ("INSERT INTO job_activity (job_id, at, text) VALUES (?, ?, ?)", [id, ms(a.at), a.text])
    }

    // MARK: Runs

    @discardableResult
    func addRun(_ new: Run) -> Int {
        nextRun += 1
        var r = new
        r.id = nextRun
        runs.insert(r, at: 0)
        write(("INSERT INTO runs (id, job_id, started, duration_ms, since, error, kind, tickets) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
               [r.id, r.jobID, ms(r.started), Int(r.duration * 1000), r.since, r.error, r.kind.rawValue, encode(r.tickets)]))
        return r.id
    }

    func run(_ id: Int) -> Run? { runs.first { $0.id == id } }

    func runs(for jobID: Int) -> [Run] { runs.filter { $0.jobID == jobID } }

    func deleteRuns(_ ids: Set<Int>) {
        runs.removeAll { ids.contains($0.id) }
        write(contentsOf: ids.map { ("DELETE FROM runs WHERE id = ?", [$0]) })
    }

    /// The job's newest run that really synced; dry runs don't count.
    func lastRun(_ jobID: Int) -> Run? { runs.first { $0.jobID == jobID && $0.kind != .dryRun } }

    // MARK: Settings

    func setSetting(_ key: String, _ value: String) {
        guard settings[key] != value else { return }
        settings[key] = value
        write(("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value]))
    }

    /// The saved value mappings, defaults filled in; a missing or broken value means the defaults.
    var rules: Rules { ((try? decode(settings[Setting.rules] ?? "")) ?? Rules()).orDefault() }

    func setRules(_ r: Rules) { setSetting(Setting.rules, encode(r)) }

    /// The user mapping every job falls back to.
    var sharedUsers: [UserPair] { (try? decode(settings[Setting.sharedUsers] ?? "")) ?? [] }

    func setSharedUsers(_ u: [UserPair]) { setSetting(Setting.sharedUsers, encode(u)) }
}

extension Store: SyncState {
    func cursor(job: Int) throws -> String {
        guard let db else { return memCursors[job] ?? "" }
        return try db.query("SELECT cursor FROM sync_state WHERE job_id = ?", job).first.map { str($0[0]) } ?? ""
    }

    func setCursor(job: Int, _ iso: String) throws {
        guard let db else { memCursors[job] = iso; return }
        try db.exec("INSERT INTO sync_state (job_id, cursor) VALUES (?, ?) ON CONFLICT(job_id) DO UPDATE SET cursor = excluded.cursor", job, iso)
    }

    func commentMappings(workItem: Int) throws -> [String: CommentMapping] {
        guard let db else { return memComments[workItem] ?? [:] }
        var out: [String: CommentMapping] = [:]
        for r in try db.query("SELECT jira_comment_id, ado_comment_id, jira_updated FROM comment_mappings WHERE ado_work_item_id = ?", workItem) {
            out[str(r[0])] = CommentMapping(workItemID: workItem, jiraCommentID: str(r[0]), adoCommentID: int(r[1]), jiraUpdated: str(r[2]))
        }
        return out
    }

    func saveCommentMapping(_ m: CommentMapping) throws {
        guard let db else { memComments[m.workItemID, default: [:]][m.jiraCommentID] = m; return }
        try db.exec("""
            INSERT INTO comment_mappings (ado_work_item_id, jira_comment_id, ado_comment_id, jira_updated) VALUES (?, ?, ?, ?)
            ON CONFLICT(ado_work_item_id, jira_comment_id) DO UPDATE SET ado_comment_id = excluded.ado_comment_id, jira_updated = excluded.jira_updated
            """, m.workItemID, m.jiraCommentID, m.adoCommentID, m.jiraUpdated)
    }
}

/// Settings keys in the store.
enum Setting {
    static let adoOrg = "ado_org"
    static let adoUser = "ado_user"
    static let jiraURL = "jira_url"
    static let jiraEmail = "jira_email"
    static let jqlExtra = "jql_extra"
    static let jiraKeyField = "jira_key_field"
    static let theme = "theme"
    static let notify = "notify"
    static let appIcon = "app_icon"
    static let menuBar = "menu_bar"
    static let rules = "mapping_rules"
    static let sharedUsers = "shared_users"
}

private func str(_ v: Any?) -> String { v as? String ?? "" }
private func int(_ v: Any?) -> Int { Int(v as? Int64 ?? 0) }
private func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }
private func date(_ v: Any?) -> Date { Date(timeIntervalSince1970: Double(int(v)) / 1000) }

func encode<T: Encodable>(_ v: T) -> String {
    String(decoding: (try? JSONEncoder().encode(v)) ?? Data("null".utf8), as: UTF8.self)  // only our own plain types
}

func decode<T: Decodable>(_ s: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(s.utf8)) }
