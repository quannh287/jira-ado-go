import Foundation

// MARK: - ADO fields the sync can write

enum Field {
    static let title = "System.Title"
    static let description = "System.Description"
    static let state = "System.State"
    static let priority = "Microsoft.VSTS.Common.Priority"
    static let assignedTo = "System.AssignedTo"
    static let createdBy = "System.CreatedBy"
    static let startDate = "Microsoft.VSTS.Scheduling.StartDate"
    static let targetDate = "Microsoft.VSTS.Scheduling.TargetDate"
    static let originalEstimate = "Microsoft.VSTS.Scheduling.OriginalEstimate"
    static let remainingWork = "Microsoft.VSTS.Scheduling.RemainingWork"
    static let completedWork = "Microsoft.VSTS.Scheduling.CompletedWork"
    static let area = "System.AreaPath"
    static let iteration = "System.IterationPath"

    /// Every pair the engine knows, in the source app's order; a job's mappings select among them.
    static let supported: [FieldPair] = [
        .init(jira: "summary", ado: title), .init(jira: "description", ado: description),
        .init(jira: "status", ado: state), .init(jira: "priority", ado: priority),
        .init(jira: "assignee", ado: assignedTo), .init(jira: "reporter", ado: createdBy),
        .init(jira: "created", ado: startDate), .init(jira: "duedate", ado: targetDate),
        .init(jira: "aggregatetimeoriginalestimate", ado: originalEstimate),
        .init(jira: "aggregatetimeestimate", ado: remainingWork),
        .init(jira: "aggregatetimespent", ado: completedWork),
    ]
}

// MARK: - Value rules

let typePBI = "Product Backlog Item"
let typeTask = "Task"

/// Jira values → ADO values. Keys match case-insensitively; empty parts fall back to the defaults.
struct Rules: Codable, Hashable {
    var types: [String: String] = [:]  // Jira issue type → ADO work item type
    var subtaskType = ""
    var defaultType = ""
    var states: [String: String] = [:]  // Jira status → ADO state, backlog items
    var taskStates: [String: String] = [:]  // Jira status → ADO state, Tasks
    var priorities: [String: String] = [:]  // Jira priority → 1–4

    /// The source app's hardcoded mappings.
    static let defaults = Rules(
        subtaskType: typeTask, defaultType: typePBI,
        states: ["To Do": "New", "In Progress": "In Progress", "In Review": "Verify Test", "Done": "Done"],
        taskStates: ["To Do": "To Do", "In Progress": "In Progress", "In Review": "Verify Test", "Done": "Done"],
        priorities: ["Highest": "1", "High": "2", "Medium": "3", "Low": "4", "Lowest": "4"])

    func orDefault() -> Rules {
        var d = Rules.defaults
        d.types = types
        if !subtaskType.isEmpty { d.subtaskType = subtaskType }
        if !defaultType.isEmpty { d.defaultType = defaultType }
        if !states.isEmpty { d.states = states }
        if !taskStates.isEmpty { d.taskStates = taskStates }
        if !priorities.isEmpty { d.priorities = priorities }
        return d
    }

    func workItemType(_ issueType: String, subtask: Bool) -> String {
        if let t = lookup(types, issueType), !t.isEmpty { return t }
        return subtask ? subtaskType : defaultType
    }

    /// Maps a Jira status for an ADO type, falling back to the type's initial state.
    func state(_ adoType: String, _ jiraStatus: String) -> String {
        if let s = lookup(isTask(adoType) ? taskStates : states, jiraStatus), !s.isEmpty { return s }
        return initialState(adoType)
    }

    /// "4" when unknown, as the source did.
    func priority(_ jira: String) -> String {
        if let p = lookup(priorities, jira), !p.isEmpty { return p }
        return "4"
    }
}

func lookup(_ m: [String: String], _ key: String) -> String? {
    let key = key.trimmingCharacters(in: .whitespaces)
    if let v = m[key] { return v }
    return m.first { $0.key.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame }?.value
}

/// Tasks get estimates, no target date, and Task states.
func isTask(_ adoType: String) -> Bool { adoType.caseInsensitiveCompare(typeTask) == .orderedSame }

/// The state ADO lets a work item be created in.
func initialState(_ adoType: String) -> String { isTask(adoType) ? "To Do" : "New" }
