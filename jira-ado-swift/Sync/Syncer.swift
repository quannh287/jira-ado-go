import Foundation

// The real Jira→ADO engine, ported from the source app's app/api/sync/jobs/[id]/run/route.ts.

protocol JiraAPI {
    func sprintFields() async throws -> [String]
    func timeZone() async throws -> TimeZone
    func search(_ jql: String, fields: [String]) async throws -> [JiraIssue]
    func comments(_ key: String) async throws -> [JiraComment]
    func download(_ url: String) async throws -> Data
}

protocol ADOAPI {
    func nodeExists(kind: String, path: String) async throws -> Bool
    func find(field: String, value: String) async throws -> Int
    func get(_ id: Int) async throws -> WorkItem
    func create(type: String, ops: [PatchOp]) async throws -> Int
    func update(_ id: Int, ops: [PatchOp]) async throws
    func parentRelation(_ parentID: Int) -> PatchOp
    func removeAttachments(_ id: Int, _ rels: [Relation]) async throws
    func attach(_ id: Int, name: String, data: Data) async throws
    func addComment(_ id: Int, html: String) async throws -> Int
    func updateComment(_ id: Int, commentID: Int, html: String) async throws
}

extension JiraClient: JiraAPI {}
extension ADOClient: ADOAPI {}

/// The real engine. Each sync builds its own clients, so concurrent runs never share a PAT or a log.
final class Syncer: SyncEngine {
    let state: SyncState
    let now: () -> Date
    /// Swapped in tests for fakes.
    var clients: (Connection, String, @escaping (APICall) -> Void) -> (JiraAPI, ADOAPI) = { conn, project, onCall in
        let a = ADOClient(org: conn.adoOrg, project: project, pat: conn.pat)
        a.onCall = onCall
        return (JiraClient(baseURL: conn.jiraURL, email: conn.jiraEmail, token: conn.jiraToken), a)
    }

    init(state: SyncState, now: @escaping () -> Date = Date.init) {
        self.state = state
        self.now = now
    }

    func validatePAT(org: String, pat: String) async throws -> String {
        try await ADOClient.connectionData(org: org, pat: pat)
    }

    func checkJira(_ conn: Connection) async throws -> String {
        guard !conn.jiraURL.isEmpty, !conn.jiraEmail.isEmpty, !conn.jiraToken.isEmpty else {
            throw Failure("set the Jira URL, email and API token first")
        }
        return try await JiraClient(baseURL: conn.jiraURL, email: conn.jiraEmail, token: conn.jiraToken).myself()
    }

    func sync(_ conn: Connection, _ job: Job, _ opts: RunOptions) async -> Run {
        let start = now()
        var out = Run(jobID: job.id, started: start, kind: opts.dryRun ? .dryRun : opts.keys.isEmpty ? .sync : .retry)
        let tag = "\(job.id)-\(Int(start.timeIntervalSince1970))"  // ties this sync's log lines together
        AppLog.info("sync start", ["run": tag, "job": job.id, "jira": job.jiraKey, "ado": job.adoProject, "kind": out.kind.rawValue])
        await body(conn, job, opts, &out)
        out.duration = now().timeIntervalSince(start)
        let attrs: KeyValuePairs<String, Any> = ["run": tag, "since": out.since, "duration": fmtDuration(out.duration), "tickets": out.tickets.count,
                                                 "created": out.count(.created), "updated": out.count(.updated),
                                                 "skipped": out.count(.skipped), "failed": out.count(.failed), "err": out.error]
        if out.error.isEmpty { AppLog.info("sync done", attrs) } else { AppLog.error("sync failed", attrs) }
        return out
    }

    private func body(_ conn: Connection, _ job: Job, _ opts: RunOptions, _ out: inout Run) async {
        let r: SyncRun
        do { r = try newRun(conn, job, dry: opts.dryRun) } catch { out.error = describe(error); return }
        let moveCursor = opts.keys.isEmpty && !opts.dryRun
        var since = ""
        if opts.keys.isEmpty {
            do { since = try r.state.cursor(job: job.id) } catch { out.error = "read cursor: " + describe(error); return }
            r.firstRun = since.isEmpty
        }
        out.since = since
        // Preflight: anything here would fail every ticket, so stop before a single write.
        do {
            let problems = try await r.preflight()
            if !problems.isEmpty { out.error = stopReason(nil, problems); return }
        } catch { out.error = stopReason(error, []); return }
        let issues: [JiraIssue]
        do { issues = opts.keys.isEmpty ? try await r.detect(since) : try await r.byKeys(opts.keys) } catch {
            out.error = stopReason(error, [])
            return
        }
        AppLog.info("issues detected", ["job": job.id, "count": issues.count, "since": since, "first_run": r.firstRun])

        opts.onProgress?(SyncProgress(run: out, done: 0, total: issues.count))
        let cp = Checkpoint(issues)
        var details: [String: JiraIssue] = [:], fetched = Set<String>()
        for (i, issue) in issues.enumerated() {
            if Task.isCancelled {
                out.error = stopReason(CancellationError(), [])
                return  // cursor stays at the last checkpoint, so the next run resumes here
            }
            if i % detailBatch == 0 {
                await r.fetchDetails(Array(issues[i..<min(i + detailBatch, issues.count)]), into: &details, fetched: &fetched)
            }
            let t = await r.process(issue, details, fetched: fetched.contains(issue.id))
            out.tickets.append(t)
            opts.onProgress?(SyncProgress(run: out, done: out.tickets.count, total: issues.count))
            if t.outcome == .failed {
                AppLog.warn("ticket failed", ["key": t.key, "ado_id": t.adoID, "type": t.workItemType, "err": t.error])
            } else if t.message.contains(" · ") {  // attachment/comment warnings
                AppLog.warn("ticket synced with warnings", ["key": t.key, "ado_id": t.adoID, "msg": t.message])
            }
            // Checkpoint per issue; a failed issue still advances it on purpose — its ticket is the record to rerun.
            if let iso = cp.advance(issue.id), moveCursor {
                do { try r.state.setCursor(job: job.id, iso) } catch { AppLog.error("save checkpoint", ["cursor": iso, "err": describe(error)]) }
            }
        }
        // Only close the window when something was processed: a broken query returning 0 issues must not swallow the backlog.
        if !issues.isEmpty && moveCursor {
            do { try r.state.setCursor(job: job.id, isoTime(out.started)) } catch { AppLog.error("save cursor", ["err": describe(error)]) }
        }
    }

    /// The clients and state of one run; in a dry run the ADO and state writes are only recorded.
    private func newRun(_ conn: Connection, _ job: Job, dry: Bool) throws -> SyncRun {
        if let m = conn.missing { throw Failure("Not configured: \(m) (Settings)") }
        var conn = conn
        if conn.jiraKeyField.isEmpty { conn.jiraKeyField = Defaults.jiraKeyField }
        let r = SyncRun(conn: conn, job: job, now: now, state: state, dry: dry)
        let (jira, ado) = clients(conn, job.adoProject) { [weak r] c in r?.calls?.append(c) }
        r.jira = jira
        r.ado = dry ? DryADO(base: ado) { [weak r] c in r?.calls?.append(c) } : ado
        if dry { r.state = ReadOnlyState(base: state) }
        return r
    }

    /// The preflight on its own, for the job editor.
    func check(_ conn: Connection, _ job: Job) async throws -> [String] {
        try await newRun(conn, job, dry: true).preflight()
    }

    /// Jira issue types, statuses and priorities, ADO work item types and their states.
    /// A failure on one side still returns the other side's lists, with the error.
    func catalog(_ conn: Connection, jiraProjects: [String], adoProjects: [String]) async -> (Catalog, String?) {
        var cat = Catalog()
        if let m = conn.missing { return (cat, "set the \(m) in Settings first") }
        var errs: [String] = []
        let jc = JiraClient(baseURL: conn.jiraURL, email: conn.jiraEmail, token: conn.jiraToken)
        var types: [[String]] = [], statuses: [[String]] = []
        for p in jiraProjects {
            do {
                let (t, s) = try await jc.projectStatuses(p)
                types.append(t)
                statuses.append(s)
            } catch { errs.append(describe(error)) }
        }
        cat.jiraTypes = union(types)
        cat.jiraStatuses = union(statuses)
        do { cat.jiraPriorities = try await jc.priorities() } catch { errs.append(describe(error)) }
        var adoTypes: [[String]] = []
        for p in adoProjects {
            let ac = ADOClient(org: conn.adoOrg, project: p, pat: conn.pat)
            let ts: [String]
            do { ts = try await ac.workItemTypes() } catch {
                errs.append("ADO work item types of \(p): \(describe(error))")
                continue
            }
            adoTypes.append(ts)
            for t in ts where cat.adoStates[t] == nil {
                do { cat.adoStates[t] = try await ac.states(t) } catch { errs.append("ADO states of \(t): \(describe(error))") }
            }
        }
        cat.adoTypes = union(adoTypes).sorted()
        return (cat, errs.isEmpty ? nil : errs.joined(separator: "\n"))
    }
}

/// How many issues one Jira search fetches in full; one search per issue was the source's N+1.
let detailBatch = 50

/// Adds issuetype and parent to the source app's id/subtasks/updated: the parents-first sort needs them.
let searchFields = ["id", "subtasks", "updated", "issuetype", "parent"]

/// Why a run stopped: cancelled, preflight problems, or the error.
func stopReason(_ err: Error?, _ problems: [String]) -> String {
    if Task.isCancelled || err is CancellationError { return "Cancelled" }
    if !problems.isEmpty { return "Preflight: " + problems.joined(separator: "; ") + ". Nothing was written." }
    return err.map(describe) ?? ""
}

/// One sync's working state.
final class SyncRun {
    let conn: Connection
    let job: Job
    let now: () -> Date
    var state: SyncState
    let rules: Rules
    let dry: Bool
    var jira: JiraAPI!
    var ado: ADOAPI!
    /// The current ticket's ADO calls.
    var calls: [APICall]?
    /// "KEY - id" → ADO work item for the run, so sub-tasks don't look up the same parent again.
    var ids: [String: Int] = [:]
    /// The Jira account's time zone; nil means unknown, so JQL reads 12h further back.
    var zone: TimeZone? = TimeZone(identifier: "UTC")
    /// No cursor: the whole backlog is imported, so Done items are skipped without a comment each.
    var firstRun = false
    /// Jira's Sprint custom field, read when iterations follow the Jira sprint.
    var sprintFields: [String] = []

    init(conn: Connection, job: Job, now: @escaping () -> Date, state: SyncState, dry: Bool) {
        self.conn = conn
        self.job = job
        self.now = now
        self.state = state
        self.rules = conn.rules.orDefault()
        self.dry = dry
    }

    /// What would fail every ticket: a missing area or iteration path, or no Sprint field to place issues by.
    func preflight() async throws -> [String] {
        var problems: [String] = []
        let (area, iteration) = job.paths(at: now())
        var paths = [("areas", area), ("iterations", iteration)]
        if job.filters.autoPaths {
            paths.append(("iterations", job.backlogPath))
            // Without the Sprint field every issue would look out of sprint and be moved to the backlog.
            sprintFields = try await jira.sprintFields()
            if sprintFields.isEmpty { problems.append("Jira has no Sprint field this account can read, so issues can't be placed by sprint") }
        }
        for (kind, path) in paths {
            let label = kind == "areas" ? "Area" : "Iteration"
            if path.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("No \(label.lowercased()) path set")
                continue
            }
            if !(try await ado.nodeExists(kind: kind, path: path)) {
                problems.append("\(label) path \(jqlQuote(path)) doesn't exist in ADO project \(job.adoProject)")
            }
        }
        return problems
    }

    /// Just the given issues, for Retry failed.
    func byKeys(_ keys: [String]) async throws -> [JiraIssue] {
        let jql = "key in (\(keys.map(jqlQuote).joined(separator: ","))) AND project = \(jqlQuote(job.jiraKey))"
        return parentsFirst(try await jira.search(jql, fields: searchFields))
    }

    /// Loads the full fields of a batch; on failure the issues fall back to one search each in process.
    func fetchDetails(_ batch: [JiraIssue], into: inout [String: JiraIssue], fetched: inout Set<String>) async {
        let ids = batch.map(\.id)
        do {
            for d in try await jira.search(scopedJQL("id in (\(ids.joined(separator: ",")))"), fields: JiraClient.allFields) { into[d.id] = d }
            fetched.formUnion(ids)
        } catch {
            AppLog.warn("batch detail fetch failed; fetching one by one", ["issues": ids.count, "err": describe(error)])
        }
    }

    /// Issues updated since the cursor, plus sub-tasks of those parents, parents first.
    func detect(_ since: String) async throws -> [JiraIssue] {
        if !since.isEmpty {
            do { zone = try await jira.timeZone() } catch {
                AppLog.warn("Jira time zone unknown; reading 12h further back so no issue is missed", ["job": job.id, "err": describe(error)])
                zone = nil
            }
        }
        let assignees = job.filters.userFilter ? job.filters.assigneeList : []
        var issues = try await jira.search(searchJQL(since, assignees), fields: searchFields)
        // Jira answers an empty 200 when it can't resolve a user in `assignee in`, so retry unfiltered and filter in the loop.
        if issues.isEmpty && !assignees.isEmpty {
            let all = try await jira.search(searchJQL(since, []), fields: searchFields)
            if !all.isEmpty {
                AppLog.warn("assignee filter matched nothing; refetched without it", ["job": job.id, "unfiltered": all.count])
                issues = all
            }
        }
        // An updated parent doesn't mean its sub-tasks changed, so pull in sub-tasks the cursor would miss.
        var known = Set(issues.map(\.id)), missing: [String] = []
        for s in issues.flatMap(\.subtasks) where known.insert(s.id).inserted { missing.append(s.id) }
        if !missing.isEmpty {
            issues += try await jira.search("id in (\(missing.joined(separator: ",")))", fields: searchFields)
        }
        return parentsFirst(issues)
    }

    func searchJQL(_ since: String, _ assignees: [String]) -> String {
        var parts: [String] = []
        if !since.isEmpty, let t = parseJiraTime(since) { parts.append("updated >= \"\(jqlTime(t, zone))\"") }
        parts.append("project = \(jqlQuote(job.jiraKey))")
        if !conn.jqlExtra.isEmpty { parts.append("(\(conn.jqlExtra))") }
        if !assignees.isEmpty { parts.append("assignee in (\(assignees.map(jqlQuote).joined(separator: ",")))") }
        return parts.joined(separator: " AND ") + " ORDER BY updated ASC"
    }

    /// Limits clause to the job's project and the extra JQL.
    func scopedJQL(_ clause: String) -> String {
        var parts = [clause, "project = \(jqlQuote(job.jiraKey))"]
        if !conn.jqlExtra.isEmpty { parts.append("(\(conn.jqlExtra))") }
        return parts.joined(separator: " AND ")
    }

    /// Resolves "KEY - id" to an ADO work item once per run; 0 when there is none yet.
    func findID(_ link: String) async throws -> Int {
        if let id = ids[link] { return id }
        let id = try await ado.find(field: conn.jiraKeyField, value: link)
        if id != 0 { ids[link] = id }  // not-found isn't cached: this run may create it
        return id
    }
}

/// Parents before sub-tasks (stable), so a sub-task can link to its parent's work item.
func parentsFirst(_ issues: [JiraIssue]) -> [JiraIssue] {
    let sub = { (i: JiraIssue) in i.isSubtaskType || i.parent != nil }
    return issues.filter { !sub($0) } + issues.filter(sub)
}

/// t as Jira reads JQL dates: wall-clock time in the account's zone, to the minute (rounded down, so the window never
/// starts late). Without a zone it goes 12h back: read in any zone (UTC-12…UTC+14) it starts no later than t.
func jqlTime(_ t: Date, _ zone: TimeZone?) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy/MM/dd HH:mm"
    f.timeZone = zone ?? TimeZone(identifier: "UTC")
    return f.string(from: zone == nil ? t.addingTimeInterval(-12 * 3600) : t)
}

/// Reads Jira's "2006-01-02T15:04:05.000-0700" and ISO 8601 cursors; nil on failure.
func parseJiraTime(_ s: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    if let d = f.date(from: s) { return d }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: s)
}

func isoTime(_ d: Date) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.string(from: d)
}

/// A watermark: it passes time T only once every issue updated at or before T is done.
/// Issues run parents-first, not updated-ascending, so the last finished issue's time could skip older sub-tasks.
final class Checkpoint {
    private let byUpdated: [JiraIssue]
    private var pending: Set<String>
    private var mark = 0
    private var last = ""

    init(_ issues: [JiraIssue]) {
        byUpdated = issues.enumerated().sorted {
            let a = parseJiraTime($0.element.updated) ?? .distantPast, b = parseJiraTime($1.element.updated) ?? .distantPast
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        pending = Set(issues.map(\.id))
    }

    /// Marks id done and returns a cursor that is safe to save, or nil when the watermark didn't move.
    func advance(_ id: String) -> String? {
        pending.remove(id)
        while mark < byUpdated.count && !pending.contains(byUpdated[mark].id) { mark += 1 }
        guard mark > 0 else { return nil }
        let iso = byUpdated[mark - 1].updated
        guard !iso.isEmpty, iso != last else { return nil }
        last = iso
        return iso
    }
}

// MARK: - Dry run

/// The response a dry run records for a write it held back.
let notSent = "dry run: not sent"

/// Lets reads through and records every write instead of sending it.
final class DryADO: ADOAPI {
    private let base: ADOAPI
    private let log: (APICall) -> Void
    private var next = 0  // fake IDs for work items "created" by the dry run

    init(base: ADOAPI, log: @escaping (APICall) -> Void) {
        self.base = base
        self.log = log
    }

    private func record(_ method: String, _ path: String, _ body: Any?) {
        log(APICall(method: method, url: path, request: body.map { String(decoding: jsonData($0, pretty: true), as: UTF8.self) } ?? "null", response: notSent))
    }

    func nodeExists(kind: String, path: String) async throws -> Bool { try await base.nodeExists(kind: kind, path: path) }
    func find(field: String, value: String) async throws -> Int { try await base.find(field: field, value: value) }
    func get(_ id: Int) async throws -> WorkItem { try await base.get(id) }
    func parentRelation(_ parentID: Int) -> PatchOp { base.parentRelation(parentID) }

    func create(type: String, ops: [PatchOp]) async throws -> Int {
        record("POST", "/wit/workitems/$\(pathEscape(type))", ops.map(\.json))
        next -= 1
        return next
    }

    func update(_ id: Int, ops: [PatchOp]) async throws { record("PATCH", "/wit/workitems/\(id)", ops.map(\.json)) }

    func removeAttachments(_ id: Int, _ rels: [Relation]) async throws { record("PATCH", "/wit/workitems/\(id) (remove attachments)", nil) }

    func attach(_ id: Int, name: String, data: Data) async throws {
        record("POST", "/wit/attachments?fileName=\(queryEscape(name)) (link to #\(id))", ["bytes": data.count])
    }

    func addComment(_ id: Int, html: String) async throws -> Int {
        record("POST", "/wit/workItems/\(id)/comments", ["text": html])
        return 0
    }

    func updateComment(_ id: Int, commentID: Int, html: String) async throws {
        record("PATCH", "/wit/workItems/\(id)/comments/\(commentID)", ["text": html])
    }
}

/// Reads the real cursor and mappings but keeps the dry run from moving them.
struct ReadOnlyState: SyncState {
    let base: SyncState
    func cursor(job: Int) throws -> String { try base.cursor(job: job) }
    func setCursor(job: Int, _ iso: String) throws {}
    func commentMappings(workItem: Int) throws -> [String: CommentMapping] { try base.commentMappings(workItem: workItem) }
    func saveCommentMapping(_ m: CommentMapping) throws {}
}
