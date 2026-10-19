import Foundation

// Jira→ADO sync jobs, independent of the UI.

enum JobStatus: String, Codable, CaseIterable { case active = "ACTIVE", paused = "PAUSED" }

/// Unknown stored values, such as the removed "Webhook", load as manual (see Store.load).
enum SyncType: String, Codable, CaseIterable { case manual = "Manual", scheduler = "Scheduler" }

struct FieldPair: Codable, Hashable {
    var jira: String
    var ado: String
    var label: String { "\(jira) → \(ado)" }
}

struct UserPair: Codable, Hashable {
    var jira = ""
    var adoEmail = ""
}

// ponytail: synthesized Codable; switch to decodeIfPresent when a field is added, or old rows stop loading
struct Filters: Codable, Hashable {
    var syncComments = true
    // On: assignees non-empty → assignee must match one; empty → assignee must resolve through users.
    var userFilter = true
    var assignees = ""  // comma-separated Jira users (email or display name)
    var users: [UserPair] = []
    var areaPath = Defaults.areaPath
    // Issues in an active Jira sprint go to sprintRoot\Sprint N (N = anchorSprint + weeks since anchorDate), others to sprintRoot.
    var autoPaths = true
    var iteration = ""
    var sprintRoot = Defaults.sprintRoot
    var anchorSprint = Defaults.anchorSprint
    var anchorDate = Defaults.anchorDate  // yyyy-mm-dd, UTC start of anchorSprint
    // Optional so jobs saved before it still decode; on, an existing item keeps whatever iteration ADO has.
    var keepIteration: Bool?
    var commentIteration: Bool?  // with keepIteration, comment the kept difference on the ADO item
    var futureSprints: Bool?  // a sprint Jira hasn't started yet also counts as the current one
    var everyMinutes = 0  // Scheduler jobs; 0 = an hour

    /// How long a Scheduler job waits after its last run.
    var every: TimeInterval { everyMinutes <= 0 ? 3600 : TimeInterval(everyMinutes * 60) }

    var assigneeList: [String] {
        assignees.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

enum Defaults {
    static let areaPath = #"Tickets\KPL\KAI"#
    static let sprintRoot = #"Tickets\Weekly Sprint"#
    static let anchorSprint = 63
    static let anchorDate = "2026-06-01"
    static let jiraKeyField = "Custom.JiraID"
}

struct Activity: Codable, Hashable {
    var at: Date
    var text: String
}

struct Job: Identifiable, Hashable {
    var id = 0
    var name = ""
    var jiraKey = ""
    var adoProject = ""
    var type = SyncType.manual
    var status = JobStatus.active
    var mappings: [FieldPair] = []
    var filters = Filters()
    var created = Date()
    var activity: [Activity] = []

    var backlogPath: String { filters.sprintRoot.isEmpty ? Defaults.sprintRoot : filters.sprintRoot }

    /// The area path, and the iteration of an issue in an active Jira sprint, for a run at t.
    func paths(at t: Date) -> (area: String, iteration: String) {
        let f = filters
        guard f.autoPaths else { return (f.areaPath, f.iteration) }
        let anchor = f.anchorSprint == 0 ? Defaults.anchorSprint : f.anchorSprint
        let date = f.anchorDate.isEmpty ? Defaults.anchorDate : f.anchorDate
        return (f.areaPath, "\(backlogPath)\\Sprint \(sprintNumber(anchor: anchor, anchorDate: date, at: t))")
    }

    /// Title is always written; other fields only when mapped.
    func writes(_ adoField: String) -> Bool {
        adoField == Field.title || mappings.contains { $0.ado == adoField }
    }
}

let utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// Parses yyyy-mm-dd as a UTC day, or nil.
func parseDay(_ s: String) -> Date? {
    let p = s.trimmingCharacters(in: .whitespaces).split(separator: "-")
    guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), p[0].count == 4,
          let date = utcCalendar.date(from: DateComponents(year: y, month: m, day: d)),
          utcCalendar.component(.day, from: date) == d else { return nil }
    return date
}

/// anchor + whole weeks (floored) from anchorDate to t's UTC day; an unparsable date counts as no weeks.
func sprintNumber(anchor: Int, anchorDate: String, at t: Date) -> Int {
    guard let start = parseDay(anchorDate) else { return anchor }
    let days = utcCalendar.dateComponents([.day], from: start, to: utcCalendar.startOfDay(for: t)).day ?? 0
    return anchor + Int((Double(days) / 7).rounded(.down))
}
