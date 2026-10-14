import Foundation

/// Reads the Go app's SQLite database (schema v4, JSON with Go field names) so its data can move into this app.
struct LegacySnapshot {
    var jobs: [Job] = []  // provisional IDs, which runs and cursors refer to
    var runs: [Run] = []  // oldest first
    var cursors: [Int: String] = [:]
    var comments: [CommentMapping] = []
    var settings: [String: String] = [:]

    /// When this database last synced, to pick the newest of several.
    var lastActivity: Date { runs.map(\.started).max() ?? .distantPast }

    init() {}

    init(path: String) throws {
        let db = try Database(path: path, readOnly: true)
        guard let v = try db.query("PRAGMA user_version").first?.first as? Int64, v >= 1 else {
            throw Failure("\((path as NSString).lastPathComponent) isn't a jira-ado database")
        }
        let hasCol = { (table: String, col: String) in
            (try? db.query("SELECT COUNT(*) FROM pragma_table_info('\(table)') WHERE name = ?", col).first?.first as? Int64) == 1
        }
        if v >= 2 {
            for r in try db.query("SELECT key, value FROM settings") { settings[str(r[0])] = str(r[1]) }
            for r in try db.query("SELECT job_id, cursor FROM sync_state") { cursors[int(r[0])] = str(r[1]) }
            for r in try db.query("SELECT ado_work_item_id, jira_comment_id, ado_comment_id, jira_updated FROM comment_mappings") {
                comments.append(CommentMapping(workItemID: int(r[0]), jiraCommentID: str(r[1]), adoCommentID: int(r[2]), jiraUpdated: str(r[3])))
            }
        }
        for r in try db.query("SELECT id, name, jira_key, ado_project, type, status, created, mappings, filters FROM jobs ORDER BY id") {
            var j = Job(id: int(r[0]), name: str(r[1]), jiraKey: str(r[2]), adoProject: str(r[3]),
                        type: SyncType(rawValue: str(r[4])) ?? .manual, status: JobStatus(rawValue: str(r[5])) ?? .active, created: millis(r[6]))
            j.mappings = (try? JSONDecoder().decode([GoPair].self, from: Data(str(r[7]).utf8)))?.map { FieldPair(jira: $0.Jira, ado: $0.ADO) } ?? []
            j.filters = (try JSONDecoder().decode(GoFilters.self, from: Data(str(r[8]).utf8))).filters
            jobs.append(j)
        }
        for r in try db.query("SELECT job_id, at, text FROM job_activity ORDER BY id") {
            if let i = jobs.firstIndex(where: { $0.id == int(r[0]) }) { jobs[i].activity.append(Activity(at: millis(r[1]), text: str(r[2]))) }
        }
        let runCols = v >= 3 ? "since, error, kind" : v >= 2 ? "since, error, ''" : "'', '', ''"
        for r in try db.query("SELECT id, job_id, started, duration_ms, \(runCols) FROM runs ORDER BY id") {
            runs.append(Run(id: int(r[0]), jobID: int(r[1]), started: millis(r[2]), duration: Double(int(r[3])) / 1000,
                            since: str(r[4]), error: str(r[5]), kind: RunKind(rawValue: str(r[6])) ?? .sync))
        }
        let extra = v >= 2 ? ", work_item_type, ado_id, message" : ", '', 0, ''"
        let parent = hasCol("tickets", "parent_key") ? ", parent_key" : ", ''"
        var at: [Int: Int] = [:]
        for (i, r) in runs.enumerated() { at[r.id] = i }
        for r in try db.query("SELECT run_id, key, summary, outcome, error, calls\(extra)\(parent) FROM tickets ORDER BY id") {
            guard let i = at[int(r[0])] else { continue }
            let calls = (try? JSONDecoder().decode([GoCall].self, from: Data(str(r[5]).utf8)))?.map(\.call) ?? []
            runs[i].tickets.append(Ticket(key: str(r[1]), summary: str(r[2]), parentKey: str(r[9]), outcome: Outcome(rawValue: str(r[3])) ?? .skipped,
                                          workItemType: str(r[6]), adoID: int(r[7]), message: str(r[8]), error: str(r[4]), calls: calls))
        }
        if let go = settings[Setting.rules] { settings[Setting.rules] = Self.rulesJSON(go) }
        if let go = settings[Setting.sharedUsers] { settings[Setting.sharedUsers] = Self.usersJSON(go) }
    }

    private static func rulesJSON(_ go: String) -> String? {
        guard let r = try? JSONDecoder().decode(GoRules.self, from: Data(go.utf8)) else { return nil }
        return encode(Rules(types: r.Types ?? [:], subtaskType: r.SubtaskType ?? "", defaultType: r.DefaultType ?? "",
                            states: r.States ?? [:], taskStates: r.TaskStates ?? [:], priorities: r.Priorities ?? [:]))
    }

    private static func usersJSON(_ go: String) -> String? {
        (try? JSONDecoder().decode([GoUser].self, from: Data(go.utf8))).map { encode($0.map(\.user)) }  // Go writes null for none
    }
}

// The Go app's JSON, field names as Go wrote them; nil slices and maps come as null.
private struct GoPair: Decodable { let Jira: String, ADO: String }

private struct GoUser: Decodable {
    let Jira: String, ADOEmail: String
    var user: UserPair { UserPair(jira: Jira, adoEmail: ADOEmail) }
}

private struct GoFilters: Decodable {
    let SyncComments: Bool?, UserFilter: Bool?, AutoPaths: Bool?
    let Assignees: String?, AreaPath: String?, Iteration: String?, SprintRoot: String?, AnchorDate: String?
    let AnchorSprint: Int?, EveryMinutes: Int?
    let Users: [GoUser]?

    var filters: Filters {
        var f = Filters()
        f.syncComments = SyncComments ?? false
        f.userFilter = UserFilter ?? false
        f.autoPaths = AutoPaths ?? false
        f.assignees = Assignees ?? ""
        f.areaPath = AreaPath ?? ""
        f.iteration = Iteration ?? ""
        f.sprintRoot = SprintRoot ?? ""
        f.anchorDate = AnchorDate ?? ""
        f.anchorSprint = AnchorSprint ?? 0
        f.everyMinutes = EveryMinutes ?? 0
        f.users = (Users ?? []).map(\.user)
        return f
    }
}

private struct GoRules: Decodable {
    let Types: [String: String]?, States: [String: String]?, TaskStates: [String: String]?, Priorities: [String: String]?
    let SubtaskType: String?, DefaultType: String?
}

private struct GoCall: Decodable {
    let Method: String?, URL: String?, Request: String?, Response: String?, Error: String?
    let Status: Int?, Retries: Int?
    let Duration: Int64?  // Go's time.Duration: nanoseconds

    var call: APICall {
        APICall(method: Method ?? "", url: URL ?? "", request: Request ?? "", status: Status ?? 0, response: Response ?? "",
                retries: Retries ?? 0, duration: Double(Duration ?? 0) / 1e9, error: Error ?? "")
    }
}

private func str(_ v: Any?) -> String { v as? String ?? "" }
private func int(_ v: Any?) -> Int { Int(v as? Int64 ?? 0) }
private func millis(_ v: Any?) -> Date { Date(timeIntervalSince1970: Double(int(v)) / 1000) }

extension Store {
    /// What an import brought in, for the notice.
    struct ImportSummary: Equatable {
        var jobs = 0, runs = 0, comments = 0, cursors = 0
        var text: String { "Imported \(plural(jobs, "job")), \(plural(runs, "run")), \(plural(comments, "comment link")) and \(plural(cursors, "cursor"))" }
    }

    /// Brings in the Go app's data: jobs, runs, cursors and settings from the snapshot that synced last,
    /// comment links from all of them, so no Jira comment is posted to ADO twice. One transaction: all or nothing.
    func importLegacy(_ snapshots: [LegacySnapshot]) throws -> ImportSummary {
        guard let main = snapshots.max(by: { $0.lastActivity < $1.lastActivity }) else { return ImportSummary() }
        for j in main.jobs where jobs.contains(where: { $0.jiraKey == j.jiraKey }) {
            throw Failure("A job for Jira project \(j.jiraKey) already exists; delete it first so two jobs don't sync the same project.")
        }
        var ids: [Int: Int] = [:], newJobs: [Job] = [], newRuns: [Run] = []
        var next = (jobs.map(\.id).max() ?? 0), nextRun = (runs.map(\.id).max() ?? 0)
        for var j in main.jobs {
            next += 1
            ids[j.id] = next
            j.id = next
            newJobs.append(j)
        }
        for var r in main.runs {
            guard let id = ids[r.jobID] else { continue }
            nextRun += 1
            r.id = nextRun
            r.jobID = id
            newRuns.append(r)
        }
        let cursors = main.cursors.compactMap { old, c in ids[old].map { ($0, c) } }
        // The newest edit of each comment wins when databases disagree.
        var comments: [String: CommentMapping] = [:]
        for m in snapshots.flatMap(\.comments) {
            let k = "\(m.workItemID)/\(m.jiraCommentID)"
            if comments[k].map({ $0.jiraUpdated < m.jiraUpdated }) ?? true { comments[k] = m }
        }
        try insertImported(jobs: newJobs, runs: newRuns, cursors: cursors, comments: Array(comments.values), settings: main.settings)
        return ImportSummary(jobs: newJobs.count, runs: newRuns.count, comments: comments.count, cursors: cursors.count)
    }
}
