import Foundation

// Weekly sprint planning on ADO: the config, one sprint's work items, and the day snapshots behind the chart.

/// A ceremony repeats every sprint, or only on odd/even sprint numbers (a two-week sprint over one-week iterations).
enum Parity: String, Codable, CaseIterable {
    case every, odd, even
    func matches(_ sprint: Int) -> Bool {
        switch self {
        case .every: true
        case .odd: sprint % 2 != 0
        case .even: sprint % 2 == 0
        }
    }
}

struct SprintProject: Codable, Hashable, Identifiable {
    var name = ""
    var adoProject = ""
    var areaPath = ""
    var iterationBase = ""
    var effortPct = 0

    var id: String { name }
    func budget(_ workweek: Double) -> Double { workweek * Double(effortPct) / 100 }
}

struct ActivityItem: Codable, Hashable, Identifiable {
    var title = ""
    var priority = 1
    var parity = Parity.every
    var id: String { title }

    /// "{sprint_name}" and "{sprint_number}" filled in.
    func render(_ sprint: Iteration) -> String {
        title.replacingOccurrences(of: "{sprint_name}", with: sprint.name)
            .replacingOccurrences(of: "{sprint_number}", with: "\(sprint.number)")
    }
}

struct ActivityGroup: Codable, Hashable, Identifiable {
    var project = ""
    var parentID = 0
    var items: [ActivityItem] = []
    var id: String { project }
}

/// Stored as one JSON value in settings; the sprint page does nothing until it has a project.
struct SprintConfig: Codable, Hashable {
    var adoEmail = ""
    var workweekHours = 40.0
    var projects: [SprintProject] = []
    var activities: [ActivityGroup] = []

    var configured: Bool { !adoEmail.isEmpty && !projects.isEmpty }
    var budget: Double { projects.reduce(0) { $0 + $1.budget(workweekHours) } }
    func activityGroup(_ project: String) -> ActivityGroup? { activities.first { $0.project == project } }

    /// Migrated from ~/.claude/sprint-planning.yaml; seeded once, then Settings owns it.
    static let seed = SprintConfig(
        adoEmail: "quan.nguyen@atstechnology.vn", workweekHours: 40,
        projects: [
            .init(name: "KAI-GO", adoProject: "Tickets", areaPath: #"Tickets\KPL\KAI"#, iterationBase: #"Tickets\Weekly Sprint"#, effortPct: 50),
            .init(name: "GAL-GCC", adoProject: "Tickets", areaPath: #"Tickets\GAL\GCC"#, iterationBase: #"Tickets\Weekly Sprint"#, effortPct: 50),
            .init(name: "DIGITAL-LIBRARY", adoProject: "Tickets", areaPath: #"Tickets\ATS\DGL"#, iterationBase: #"Tickets\Weekly Sprint"#, effortPct: 0),
        ],
        activities: [
            .init(project: "KAI-GO", parentID: 24446, items: [
                .init(title: "[KAI] Activities | Quan Nguyen | {sprint_name} | Sprint Planning", priority: 1, parity: .odd),
                .init(title: "[KAI] Activities | Quan Nguyen | {sprint_name} | Sprint Retrospective", priority: 4, parity: .even),
                .init(title: "[KAI] Activities | Quan Nguyen | {sprint_name} | Prepare Sentry issues for grooming", priority: 2, parity: .even),
                .init(title: "[KAI] Activities | Quan Nguyen | {sprint_name} | Backlog Grooming", priority: 2, parity: .even),
            ]),
            .init(project: "GAL-GCC", parentID: 27445, items: [
                .init(title: "[GAL][Sprint {sprint_number}] Sprint planning", priority: 1, parity: .every),
                .init(title: "[GAL][Sprint {sprint_number}] weekly demo & reports", priority: 2, parity: .every),
            ]),
        ])
}

/// One ADO iteration node. `number` is the trailing digits of the name ("Sprint 86" → 86), 0 when it has none.
struct Iteration: Codable, Hashable, Identifiable {
    var path = ""
    var start = Date.distantPast
    var finish = Date.distantPast

    var id: String { path }
    var name: String { path.components(separatedBy: "\\").last ?? path }
    var number: Int { Int(String(name.reversed().prefix { $0.isNumber }.reversed())) ?? 0 }
    /// finishDate is that last day at midnight, so the sprint runs through the end of it.
    func contains(_ t: Date) -> Bool { t >= start && t < finish.addingTimeInterval(86400) }
    /// The five working days, Monday first.
    var days: [Date] { (0..<5).compactMap { utcCalendar.date(byAdding: .day, value: $0, to: start) } }
}

/// A work item of the sprint, flattened to the fields planning needs.
struct SprintTask: Codable, Hashable, Identifiable {
    var id = 0
    var project = ""
    var title = ""
    var type = typeTask
    var state = ""
    var estimate = 0.0
    var completed = 0.0
    var priority = 0
    var due = ""  // yyyy-MM-dd
    var parentID = 0
    var iteration = ""

    /// Only Tasks carry hours; PBI, User Story and Bug are containers the user's ADO query never sums.
    var carriesHours: Bool { isTask(type) }
    var done: Bool { state.caseInsensitiveCompare("Done") == .orderedSame || state.caseInsensitiveCompare("Closed") == .orderedSame }
    var dueDay: Date? { parseDay(due) }
}

/// What one day's snapshot says about a sprint.
struct SprintDay: Hashable {
    var day: Date
    var tasks: [SprintTask]
    var remaining: Double { tasks.filter { $0.carriesHours && !$0.done }.reduce(0) { $0 + $1.estimate } }
    var doneHours: Double { tasks.filter { $0.carriesHours && $0.done }.reduce(0) { $0 + $1.estimate } }
}

/// How a task turned out against the baseline, in the order the review reports them.
enum TaskVerdict: String, CaseIterable {
    case onTime = "done on time", late = "done late", open = "not done", movedOut = "moved out"
    case unplanned, reestimated = "re-estimated"
}

// MARK: - The weekday grid

/// P1 = Mon, P2 = Tue–Wed, P3 = Thu, P4 = Fri; the due date is the last day of the window.
func priorityOffset(_ priority: Int) -> Int {
    switch priority {
    case 1: 0
    case 2: 2
    case 3: 3
    default: 4
    }
}

/// The priority whose window holds that weekday offset (0 = Monday).
func offsetPriority(_ offset: Int) -> Int {
    switch offset {
    case ..<1: 1
    case 1, 2: 2
    case 3: 3
    default: 4
    }
}

let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri"]

/// Sums only Tasks, Done included: the week's commitment, matching the user's ADO saved query.
func committedHours(_ tasks: [SprintTask]) -> Double {
    tasks.filter(\.carriesHours).reduce(0) { $0 + $1.estimate }
}

/// yyyy-MM-dd in UTC, the form ADO date fields and the snapshot keys use.
func dayString(_ d: Date) -> String {
    let c = utcCalendar.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}
