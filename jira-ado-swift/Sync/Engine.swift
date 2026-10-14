import Foundation

/// The boundary to Jira and ADO; the UI only talks to it. Syncer is the real one, FakeEngine the demo.
protocol SyncEngine {
    /// Checks the PAT against the ADO organization and returns the user's display name.
    func validatePAT(org: String, pat: String) async throws -> String
    /// Checks the Jira credentials and returns the account's display name.
    func checkJira(_ conn: Connection) async throws -> String
    /// What would make a sync of job fail before it writes anything (missing ADO paths, no Sprint field).
    func check(_ conn: Connection, _ job: Job) async throws -> [String]
    /// Never throws: a failure is the run's error; cancelling the task stops it at the next issue.
    func sync(_ conn: Connection, _ job: Job, _ opts: RunOptions) async -> Run
    /// The values the Mappings page offers, and an error naming what couldn't load.
    func catalog(_ conn: Connection, jiraProjects: [String], adoProjects: [String]) async -> (Catalog, String?)
}

/// Simulates Jira→ADO calls with generated tickets.
// ponytail: demo engine for JIRA_ADO_DEMO=1 and UI checks; Syncer is the real one
final class FakeEngine: SyncEngine {
    var delay: TimeInterval
    var now: () -> Date
    private var rng = SplitMix(seed: 1)

    init(delay: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.delay = delay
        self.now = now
    }

    func validatePAT(org: String, pat: String) async throws -> String {
        try await wait(delay)
        guard pat.count >= 20 else { throw Failure("ADO rejected the personal access token") }
        return "Demo User"
    }

    func checkJira(_ conn: Connection) async throws -> String {
        guard !conn.jiraToken.isEmpty else { throw Failure("Jira API token is empty") }
        try await wait(delay)
        return "Demo Jira User"
    }

    func check(_ conn: Connection, _ job: Job) async throws -> [String] { [] }

    func catalog(_ conn: Connection, jiraProjects: [String], adoProjects: [String]) async -> (Catalog, String?) {
        let cat = Catalog(
            jiraTypes: ["Story", "Bug", "Task", "Sub-task", "Epic"], jiraStatuses: ["To Do", "In Progress", "In Review", "QA", "Done"],
            jiraPriorities: ["Highest", "High", "Medium", "Low", "Lowest"], adoTypes: ["Bug", "Epic", "Feature", typePBI, typeTask],
            adoStates: [typePBI: ["New", "Approved", "Committed", "In Progress", "Verify Test", "Done", "Removed"],
                        "Bug": ["New", "Approved", "Committed", "Done", "Removed"],
                        typeTask: ["To Do", "In Progress", "Verify Test", "Done", "Removed"]])
        do { try await wait(delay) } catch { return (cat, describe(error)) }
        return (cat, nil)
    }

    func sync(_ conn: Connection, _ job: Job, _ opts: RunOptions) async -> Run {
        let start = now()
        var run = Run(jobID: job.id, started: start, kind: opts.dryRun ? .dryRun : opts.keys.isEmpty ? .sync : .retry)
        let (area, iteration) = job.paths(at: start)
        let n = opts.keys.isEmpty ? 3 + rng.next(6) : opts.keys.count
        opts.onProgress?(SyncProgress(run: run, done: 0, total: n))
        for i in 0..<n {
            do { try await wait(delay / Double(n)) } catch {
                run.error = "Cancelled"
                break
            }
            var t = ticket(job, i + 1, area, iteration)
            if !opts.keys.isEmpty { t.key = opts.keys[i] }
            if i > 0 && rng.next(2) == 0 {  // about half become sub-tasks of the first ticket, as in real backlogs
                t.parentKey = run.tickets[0].key
                t.workItemType = typeTask
            }
            run.tickets.append(t)
            opts.onProgress?(SyncProgress(run: run, done: run.tickets.count, total: n))
        }
        run.duration = now().timeIntervalSince(start)
        return run
    }

    private static let summaries = [
        "Login button unresponsive on Android", "Crash when opening notifications", "Update onboarding copy",
        "Sprint report export is empty", "Add dark mode to settings", "Timeout calling payments API",
        "Profile photo upload fails", "Improve search ranking",
    ]

    private func ticket(_ j: Job, _ n: Int, _ area: String, _ iteration: String) -> Ticket {
        var t = Ticket(key: "\(j.jiraKey)-\(100 + rng.next(900))", summary: Self.summaries[rng.next(Self.summaries.count)])
        var fields = [Field.area: area, Field.iteration: iteration]
        for m in j.mappings { fields[m.ado] = "\(m.jira) of \(t.key)" }
        fields[Field.title] = t.summary
        let body = String(decoding: jsonData(fields.keys.sorted().map { ["op": "add", "path": "/fields/" + $0, "value": fields[$0]!] }, pretty: true), as: UTF8.self)
        let base = "https://dev.azure.com/org/\(j.adoProject)/_apis/wit/workitems"
        switch rng.next(10) {
        case 0..<4:
            t.outcome = .created
            t.calls = [APICall(method: "POST", url: base + "/$Bug?api-version=7.1", request: body, status: 200, response: "{\"id\": \(4000 + n), \"rev\": 1}")]
        case 4..<7:
            t.outcome = .updated
            t.calls = [APICall(method: "PATCH", url: "\(base)/\(3000 + n)?api-version=7.1", request: body, status: 200, response: "{\"id\": \(3000 + n), \"rev\": 7}")]
        case 7..<9:
            t.outcome = .skipped
            t.message = "Skipped by user filter (assignee not in scope)"
        default:
            t.outcome = .failed
            t.error = "TF401320: Rule Error for field Assigned To. Error code: Required, HasValues, InvalidListValue."
            t.calls = [APICall(method: "POST", url: base + "/$Bug?api-version=7.1", request: body, status: 400,
                               response: #"{"message": "TF401320: Rule Error for field Assigned To.", "typeKey": "RuleValidationException"}"#)]
        }
        return t
    }

    private func wait(_ d: TimeInterval) async throws {
        try Task.checkCancellation()
        if d > 0 { try await Task.sleep(for: .seconds(d)) }
    }

    /// Fills store with demo jobs and past runs.
    func seed(_ store: Store) async {
        let base = now()
        var demo = Filters()
        demo.users = [UserPair(jira: "support.lead@kai.example", adoEmail: "support.lead@kai.example")]
        var web = Filters()
        web.areaPath = #"kai-web\Platform"#
        web.autoPaths = false
        web.iteration = #"kai-web\Sprint 42"#
        let jobs = [
            Job(name: "Mobile bugs → ADO", jiraKey: "SE", adoProject: "kai-mobile", type: .manual, mappings: Field.supported),
            Job(name: "Web platform stories", jiraKey: "WEB", adoProject: "kai-web", type: .scheduler, mappings: Array(Field.supported.prefix(4)), filters: web),
            Job(name: "Support escalations", jiraKey: "SUP", adoProject: "kai-support", type: .manual, mappings: Array(Field.supported.prefix(3)), filters: demo),
        ]
        let (clock, wait) = (now, delay)
        defer { (now, delay) = (clock, wait) }
        delay = 0
        for (i, j) in jobs.enumerated() {
            let id = store.addJob(j)
            for k in stride(from: 2 - i, through: 0, by: -1) {  // oldest first; the store keeps newest first
                let at = base.addingTimeInterval(-Double(k * 7 + i * 3 + 1) * 3600)
                now = { at }
                var r = await sync(Connection(), store.job(id)!, RunOptions())
                r.duration = Double(800 + k * 450) / 1000
                store.addRun(r)
            }
        }
        store.setStatus(3, .paused)
    }
}

/// A small deterministic generator, so demo data is the same every launch.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ n: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(n))
    }
}
