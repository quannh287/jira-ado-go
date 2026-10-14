import Foundation
import Testing
@testable import jira_ado

@Test func runStatus() {
    #expect(Run().status == .success)
    #expect(Run(tickets: [Ticket(outcome: .failed)]).status == .partial)
    #expect(Run(error: "x").status == .failed)
}

@Test func runCountsAndFailedKeys() {
    let r = Run(tickets: [Ticket(key: "A", outcome: .failed), Ticket(key: "", outcome: .failed), Ticket(key: "B", outcome: .created)])
    #expect(r.count(.failed) == 2 && r.count(.created) == 1 && r.count(.skipped) == 0)
    #expect(r.failedKeys == ["A"], "a ticket without a key can't be retried")
}

@Test func filtersEveryAndAssignees() {
    var f = Filters()
    #expect(f.every == 3600, "0 minutes means an hour")
    f.everyMinutes = 15
    #expect(f.every == 900)
    f.assignees = " ana@x.io , ,Bob "
    #expect(f.assigneeList == ["ana@x.io", "Bob"])
}

@Test func jobPaths() {
    var j = Job()
    #expect(j.paths(at: t0) == (Defaults.areaPath, #"Tickets\Weekly Sprint\Sprint 82"#))
    j.filters.sprintRoot = ""
    #expect(j.backlogPath == Defaults.sprintRoot, "an empty root falls back to the default")
    j.filters.autoPaths = false
    j.filters.iteration = #"P\Fixed"#
    #expect(j.paths(at: t0).iteration == #"P\Fixed"#)
}

@Test func jobWrites() {
    let j = Job(mappings: [FieldPair(jira: "status", ado: Field.state)])
    #expect(j.writes(Field.title), "the title is always written")
    #expect(j.writes(Field.state) && !j.writes(Field.priority))
}

@Test func parseDayRejectsBadDates() {
    #expect(parseDay("2026-06-01") != nil)
    for bad in ["", "2026-6", "2026-02-30", "26-06-01", "yyyy-mm-dd"] { #expect(parseDay(bad) == nil, "\(bad)") }
    #expect(sprintNumber(anchor: 7, anchorDate: "nope", at: t0) == 7)
}

@Test func connectionMissing() {
    var c = Connection()
    let order = ["ADO organization", "ADO PAT", "Jira URL", "Jira email", "Jira API token"]
    let fill: [(inout Connection) -> Void] = [{ $0.adoOrg = "o" }, { $0.pat = "p" }, { $0.jiraURL = "u" }, { $0.jiraEmail = "e" }, { $0.jiraToken = "t" }]
    for (want, set) in zip(order, fill) {
        #expect(c.missing == want)
        set(&c)
    }
    #expect(c.missing == nil)
}

@Test func unionKeepsFirstSeenCaseInsensitive() {
    #expect(union([["Bug", "Task"], ["bug", " ", "Epic"], ["TASK"]]) == ["Bug", "Task", "Epic"])
    let cat = Catalog(adoStates: ["Bug": ["New", "Done"], "Task": ["To Do", "done"]])
    #expect(cat.statesFor(["Bug", "Task", "Missing"]) == ["New", "Done", "To Do"])
}

@Test func rulesDefaultsAndLookup() {
    let d = Rules().orDefault()
    #expect(d == Rules.defaults)
    #expect(d.workItemType("Story", subtask: false) == typePBI && d.workItemType("Sub-task", subtask: true) == typeTask)
    #expect(d.state(typePBI, "in review") == "Verify Test" && d.state(typeTask, "To Do") == "To Do")
    #expect(d.state("Bug", "Unknown") == "New" && d.state("task", "Unknown") == "To Do")
    #expect(d.priority(" highest ") == "1" && d.priority("Blocker") == "4")
    let custom = Rules(types: ["Bug": "Bug"], defaultType: "Feature").orDefault()
    #expect(custom.workItemType("BUG", subtask: false) == "Bug" && custom.workItemType("Story", subtask: false) == "Feature")
    #expect(custom.states == Rules.defaults.states, "empty parts keep the defaults")
    #expect(lookup(["  Done ": "x"], "done") == "x" && lookup([:], "a") == nil)
    #expect(isTask("TASK") && !isTask(typePBI) && initialState("Task") == "To Do" && initialState("Bug") == "New")
}

@Test func describeErrors() {
    #expect(describe(Failure("boom")) == "boom")
    #expect(describe(CancellationError()) == "Cancelled")
    #expect(describe(HTTPStatusError(method: "GET", url: "u", status: 404, body: Data("nope".utf8))) == "GET u: HTTP 404: nope")
}

// MARK: - Job editor validation

@Test func wizardSteps() {
    var j = Job()
    #expect(j.wizardError(step: 0) == "Enter a job name.")
    j.name = "Mobile"
    #expect(j.wizardError(step: 0) == "Enter the Jira project key.")
    j.jiraKey = "SE"
    #expect(j.wizardError(step: 0) == "Enter the ADO project ID.")
    j.adoProject = "kai"
    #expect(j.wizardError(step: 0) == nil && j.firstInvalidStep == 1)

    #expect(j.wizardError(step: 1) == "Map at least one field.")
    j.mappings = [Field.supported[0], Field.supported[0]]
    #expect(j.wizardError(step: 1) == "System.Title is mapped twice.")
    j.mappings = [FieldPair(jira: "x", ado: "y")]
    #expect(j.wizardError(step: 1) == "x → y isn't a pair the sync can write.")
    j.mappings = Field.supported
    #expect(j.wizardError(step: 1) == nil)

    j.filters.users = [UserPair(jira: "ana", adoEmail: "not-an-email")]
    #expect(j.wizardError(step: 2) == "Each user mapping needs a Jira user and an ADO email.")
    j.filters.users = []
    j.filters.anchorDate = "June"
    #expect(j.wizardError(step: 2) == "Enter the anchor date as yyyy-mm-dd.")
    j.filters.autoPaths = false
    #expect(j.wizardError(step: 2) == "Enter a fixed iteration path, or derive it from the weekly sprint.")
    j.filters.iteration = #"kai\S1"#
    #expect(j.wizardError(step: 2) == nil && j.firstInvalidStep == JobEditorView.steps.count)
}

// MARK: - Mappings page draft

@Test func mappingsFormRoundTrip() {
    let f = MappingsForm(rules: .defaults, users: [])
    #expect(f.error == nil)
    #expect(f.rules == Rules.defaults)
    #expect(f.states.map(\.from) == f.states.map(\.from).sorted(), "rows are sorted for a stable page")
}

@Test func mappingsFormErrors() {
    var f = MappingsForm(rules: .defaults, users: [UserPair(jira: "ana", adoEmail: "ana")])
    #expect(f.error == "Each shared user needs a Jira user and an ADO email.")
    f.users = []
    f.states.append(RulePair(from: "to do", to: "New"))
    #expect(f.error == #"Backlog item states: "to do" is mapped twice."#)
    f.states.removeLast()
    f.priorities.append(RulePair(from: "Blocker", to: "0"))
    #expect(f.error == "Priorities: ADO priority is 1, 2, 3 or 4.")
    f.priorities.removeLast()
    f.types.append(RulePair(from: "Bug", to: ""))
    #expect(f.error == "Work item types: fill in both sides of every row.")
    f.types = []
    f.subtaskType = " "
    #expect(f.error == "Work item types: set the type for sub-tasks and for everything else.")
}

@Test func mappingsFormImportsJobUsers() {
    var f = MappingsForm(rules: .defaults, users: [UserPair(jira: "Ana", adoEmail: "ana@x.io")])
    var a = Job(), b = Job()
    a.filters.users = [UserPair(jira: " ana ", adoEmail: "other@x.io"), UserPair(jira: "bob", adoEmail: "bob@x.io")]
    b.filters.users = [UserPair(jira: "BOB", adoEmail: "b@x.io"), UserPair(jira: "", adoEmail: "x@x.io")]
    #expect(f.importUsers(from: [a, b]) == 1)
    #expect(f.users.map(\.jira) == ["Ana", "bob"])
}
