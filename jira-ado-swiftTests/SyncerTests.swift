import Foundation
import Testing
@testable import jira_ado

let t0 = Date(timeIntervalSince1970: 1_791_968_400)  // 2026-10-14 09:00 UTC
let sprintFieldID = "customfield_10020"

/// Serves issues by id; the project search returns parents unless assigneeBlind hides them.
final class FakeJira: JiraAPI {
    var issues: [JiraIssue] = []
    var comments: [String: [JiraComment]] = [:]
    var jqls: [String] = []
    var assigneeBlind = false  // Jira can't resolve the users in `assignee in` and answers empty
    var failDetail = ""
    var noSprintField = false
    var zone = TimeZone(identifier: "UTC")!

    func sprintField() async throws -> String { noSprintField ? "" : sprintFieldID }
    func timeZone() async throws -> TimeZone { zone }
    func comments(_ key: String) async throws -> [JiraComment] { comments[key] ?? [] }
    func download(_ url: String) async throws -> Data { Data("file".utf8) }

    func search(_ jql: String, fields: [String]) async throws -> [JiraIssue] {
        jqls.append(jql)
        if let m = jql.firstMatch(of: #/^id = (\d+)/#) {
            if String(m.1) == failDetail { throw Failure("jira 500") }
            return byID(String(m.1))
        }
        if let m = jql.firstMatch(of: #/key in \(([^)]*)\)/#) {
            let keys = m.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return issues.filter { keys.contains("\"\($0.key)\"") }
        }
        if let m = jql.firstMatch(of: #/id in \(([^)]*)\)/#) {
            if !failDetail.isEmpty && jql.contains("project =") && m.1.contains(failDetail) { throw Failure("jira 500") }
            return m.1.split(separator: ",").flatMap { byID(String($0)) }
        }
        if assigneeBlind && jql.contains("assignee in") { return [] }
        return issues.filter { $0.parent == nil }  // sub-tasks come via backfill
    }

    private func byID(_ id: String) -> [JiraIssue] { issues.filter { $0.id == id } }
}

final class Item {
    var type: String
    var fields: JSONObject = [:]
    var parent = 0
    var comments: [Int: String] = [:]
    var attached: [String] = []
    var patches = 0
    init(type: String) { self.type = type }
}

/// An in-memory ADO that enforces the state rules the sync works around.
final class FakeADO: ADOAPI {
    var missing: Set<String> = []
    var finds = 0
    var items: [Int: Item] = [:]
    var next = 100

    func nodeExists(kind: String, path: String) async throws -> Bool { !missing.contains(path) }

    func find(field: String, value: String) async throws -> Int {
        finds += 1
        return items.first { $0.value.fields[field] as? String == value }?.key ?? 0
    }

    func get(_ id: Int) async throws -> WorkItem {
        let it = items[id]!
        var rels: [Relation] = []
        if it.parent != 0 { rels.append(Relation(rel: "System.LinkTypes.Hierarchy-Reverse", url: "https://x/_apis/wit/workItems/\(it.parent)")) }
        rels += it.attached.map { _ in Relation(rel: "AttachedFile", url: "https://x/att") }
        return WorkItem(fields: it.fields, relations: rels)
    }

    func create(type: String, ops: [PatchOp]) async throws -> Int {
        next += 1
        let it = Item(type: type)
        try apply(it, ops, creating: true)
        items[next] = it
        return next
    }

    func update(_ id: Int, ops: [PatchOp]) async throws {
        items[id]!.patches += 1
        try apply(items[id]!, ops, creating: false)
    }

    private func apply(_ it: Item, _ ops: [PatchOp], creating: Bool) throws {
        for op in ops {
            if op.path == "/relations/-" {
                let rel = op.value as! [String: String]
                if rel["rel"] == "System.LinkTypes.Hierarchy-Reverse" {
                    if it.parent != 0 { throw Failure("400: the parent link already exists") }
                    it.parent = Int(rel["url"]!.split(separator: "/").last!)!
                }
                continue
            }
            let field = String(op.path.dropFirst("/fields/".count))
            if field == Field.state, let s = op.value as? String {
                if creating && s != "New" && s != "To Do" { throw Failure("400: cannot create in state \(s)") }
                if it.fields[field] as? String == "Removed" && s != "New" && s != "To Do" { throw Failure("400: Removed can only move to the first state") }
            }
            it.fields[field] = op.value
        }
    }

    func parentRelation(_ parentID: Int) -> PatchOp {
        PatchOp(op: "add", path: "/relations/-", value: ["rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://x/_apis/wit/workItems/\(parentID)"])
    }

    func removeAttachments(_ id: Int, _ rels: [Relation]) async throws { items[id]!.attached = [] }
    func attach(_ id: Int, name: String, data: Data) async throws { items[id]!.attached.append(name) }

    func addComment(_ id: Int, html: String) async throws -> Int {
        let it = items[id]!
        it.comments[it.comments.count + 1] = html
        return it.comments.count
    }

    func updateComment(_ id: Int, commentID: Int, html: String) async throws { items[id]!.comments[commentID] = html }
}

let conn = Connection(adoOrg: "org", pat: "pat", jiraURL: "https://x.atlassian.net", jiraEmail: "e", jiraToken: "t")

func issue(_ id: String, _ key: String, _ status: String, parent: JiraRef? = nil, updated: String) -> JiraIssue {
    var f: JSONObject = [
        "summary": "\(key) summary", "created": "2026-10-01T10:00:00.000+0700", "updated": updated,
        "status": ["name": status], "priority": ["name": "High"],
        "issuetype": ["name": parent == nil ? "Story" : "Sub-task", "subtask": parent != nil],
        "assignee": ["emailAddress": "dev@kai.example", "displayName": "Dev"],
        "description": ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "a<b", "marks": [["type": "strong"]]]]]]],
    ]
    if let parent { f["parent"] = ["id": parent.id, "key": parent.key] }
    return JiraIssue(id: id, key: key, fields: f)
}

struct Setup {
    let e: Syncer, j: FakeJira, a: FakeADO, store: Store
    var job: Job

    init() {
        var parent = issue("10", "SE-1", "In Progress", updated: "2026-10-10T10:00:00.000+0700")
        parent.raw["subtasks"] = [["id": "11", "key": "SE-2"]]
        parent.raw[sprintFieldID] = [["id": 1, "state": "active"]]  // the sub-task stays out of any sprint
        var sub = issue("11", "SE-2", "To Do", parent: JiraRef(id: "10", key: "SE-1"), updated: "2026-10-02T10:00:00.000+0700")
        sub.raw["aggregatetimeoriginalestimate"] = 7200
        j = FakeJira()
        j.issues = [parent, sub]
        a = FakeADO()
        store = Store(now: { t0 })
        e = Syncer(state: store, now: { t0 })
        e.clients = { [j, a] _, _, _ in (j, a) }
        var f = Filters()
        f.users = [UserPair(jira: "DEV@kai.example", adoEmail: "dev@ado.example")]
        job = Job(id: 1, jiraKey: "SE", adoProject: "kai", mappings: Field.supported, filters: f)
    }

    func sync(_ opts: RunOptions? = nil, conn c: Connection? = nil) async -> Run { await e.sync(c ?? conn, job, opts ?? RunOptions()) }
}

@Test func firstRunCreatesParentsThenSubtasks() async throws {
    let s = Setup()
    let run = await s.sync()
    #expect(run.error == "" && run.status == .success)
    #expect(!s.j.jqls[0].contains("updated >="), "first run must import the whole backlog")
    #expect(run.tickets.map(\.key) == ["SE-1", "SE-2"] && run.count(.created) == 2)
    #expect(run.tickets[1].parentKey == "SE-1" && run.tickets[0].parentKey == "")
    let pbi = s.a.items[run.tickets[0].adoID]!, task = s.a.items[run.tickets[1].adoID]!
    #expect(pbi.type == typePBI && pbi.fields[Field.state] as? String == "In Progress" && pbi.fields[Field.priority] as? String == "2")
    #expect(pbi.fields[Field.title] as? String == "SE-1 - 10 - SE-1 summary" && pbi.fields[Field.assignedTo] as? String == "dev@ado.example")
    #expect(pbi.fields[Field.description] as? String == "<p><strong>a&lt;b</strong></p>")
    #expect(pbi.fields[Field.iteration] as? String == #"Tickets\Weekly Sprint\Sprint 82"#)
    #expect(task.fields[Field.iteration] as? String == #"Tickets\Weekly Sprint"#, "out-of-sprint task goes to the backlog")
    #expect(task.type == typeTask && task.parent != 0 && task.fields[Field.originalEstimate] as? Double == 2)
    #expect(try s.store.cursor(job: 1) == isoTime(t0))

    _ = await s.sync()  // the next run only asks for issues updated since the cursor
    #expect(s.j.jqls.contains { $0.hasPrefix(#"updated >= "2026/10/14 09:00" AND project = "SE""#) })
}

@Test func existingItemRules() async {
    let s = Setup()
    let first = await s.sync()
    let pbiID = first.tickets[0].adoID, taskID = first.tickets[1].adoID
    s.a.items[pbiID]!.fields[Field.state] = "Done"
    s.a.items[pbiID]!.fields[Field.title] = "edited in ADO"
    s.a.items[taskID]!.fields[Field.state] = "Removed"
    s.a.items[taskID]!.fields[Field.originalEstimate] = 5.0  // filled in ADO: must be kept

    let run = await s.sync()
    #expect(run.tickets[0].outcome == .skipped && s.a.items[pbiID]!.fields[Field.title] as? String == "edited in ADO")
    #expect(s.a.items[pbiID]!.comments.count == 1)
    #expect(run.tickets[1].outcome == .updated && s.a.items[taskID]!.fields[Field.state] as? String == "To Do")
    #expect(s.a.items[taskID]!.fields[Field.originalEstimate] as? Double == 5)
    #expect(s.a.items[taskID]!.comments[1]?.contains("OriginalEstimate: ADO <b>5</b> — Jira <b>2</b>") == true)
}

@Test func userFilterAndBlindAssigneeSearch() async {
    var s = Setup()
    s.job.filters.assignees = "someone else"
    s.j.assigneeBlind = true
    let run = await s.sync()
    #expect(run.count(.skipped) == 2)
    #expect(s.j.jqls[0].contains(#"assignee in ("someone else")"#) && !s.j.jqls[1].contains("assignee in"))

    var s2 = Setup()  // filter on with no names: the assignee must resolve through the user mapping
    s2.job.filters.users = []
    #expect(await s2.sync().count(.skipped) == 2)
}

@Test func failedTicketMakesRunPartial() async throws {
    let s = Setup()
    s.j.failDetail = "11"
    let run = await s.sync()
    #expect(run.status == .partial && run.tickets[1].outcome == .failed && !run.tickets[1].error.isEmpty)
    #expect(try s.store.cursor(job: 1) != "", "cursor must still advance past a failed ticket")
}

@Test func comments() async {
    let s = Setup()
    let body: JSONObject = ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "hi"]]]]]
    s.j.comments["SE-1"] = [JiraComment(id: "c1", author: JiraUser(email: "", displayName: "Ana"), body: body, updated: "u1")]
    let id = await s.sync().tickets[0].adoID
    #expect(s.a.items[id]!.comments[1] == "<div><p><strong>[Ana]:</strong></p><p>hi</p></div>")
    _ = await s.sync()  // unchanged: no duplicate
    #expect(s.a.items[id]!.comments.count == 1)
    s.j.comments["SE-1"]![0].updated = "u2"
    _ = await s.sync()
    #expect(s.a.items[id]!.comments.count == 1 && s.a.items[id]!.comments[1]!.contains("(edited)"))
}

@Test func sprintPlacement() async {
    let s = Setup()
    let id = await s.sync().tickets[0].adoID
    s.j.issues[0].raw[sprintFieldID] = [["id": 1, "state": "future"]]  // taken out of the sprint: back to the backlog
    _ = await s.sync()
    #expect(s.a.items[id]!.fields[Field.iteration] as? String == #"Tickets\Weekly Sprint"#)

    var s2 = Setup()  // without a Sprint field nothing is written
    s2.j.noSprintField = true
    let run = await s2.sync()
    #expect(run.status == .failed && s2.a.items.isEmpty && run.error.contains("Sprint field"))
    s2.job.filters.autoPaths = false  // a fixed iteration doesn't need it
    s2.job.filters.iteration = #"Tickets\Fixed"#
    let fixed = await s2.sync()
    #expect(fixed.error == "" && s2.a.items[fixed.tickets[0].adoID]!.fields[Field.iteration] as? String == #"Tickets\Fixed"#)
}

@Test func firstRunDoesNotCommentDoneItems() async throws {
    let s = Setup()
    let id = await s.sync().tickets[0].adoID
    s.a.items[id]!.fields[Field.state] = "Done"
    try s.store.setCursor(job: 1, "")  // as if this were the job's first run
    let run = await s.sync()
    #expect(run.tickets[0].outcome == .skipped && s.a.items[id]!.comments.isEmpty && run.tickets[0].message.contains("first run"))
}

@Test func progress() async {
    let s = Setup()
    var got: [SyncProgress] = []
    let run = await s.sync(RunOptions(onProgress: { got.append($0) }))
    #expect(got.count == 3 && got[0].total == 2 && got[0].done == 0 && got[2].done == 2)
    #expect(got[1].run.tickets.count == 1 && got[1].run.tickets[0].key == run.tickets[0].key)
}

@Test func preflightStopsBeforeWriting() async throws {
    let s = Setup()
    s.a.missing = [Defaults.areaPath]
    let run = await s.sync()
    #expect(run.status == .failed && run.error.contains("Area path") && run.error.contains("Nothing was written") && s.a.items.isEmpty)
    #expect(try s.store.cursor(job: 1) == "")
    #expect(try await s.e.check(conn, s.job).count == 1)
}

@Test func dryRunWritesNothing() async throws {
    let s = Setup()
    s.j.comments["SE-1"] = [JiraComment(id: "c1", author: JiraUser(email: "", displayName: "Ana"), body: nil, updated: "u1")]
    s.j.issues[0].raw["attachment"] = [["filename": "log.txt", "content": "https://x/att/1"]]
    let run = await s.sync(RunOptions(dryRun: true))
    #expect(run.kind == .dryRun && run.error == "" && run.count(.created) == 2 && s.a.items.isEmpty)
    #expect(try s.store.cursor(job: 1) == "")
    #expect(try s.store.commentMappings(workItem: 0).isEmpty)
    #expect(run.tickets[0].calls.filter { $0.response == notSent }.count >= 4 && run.tickets[0].message.hasPrefix("Would create"))
}

@Test func retryOnlyGivenKeys() async throws {
    let s = Setup()
    let run = await s.sync(RunOptions(keys: ["SE-2"]))
    #expect(run.kind == .retry && run.tickets.map(\.key) == ["SE-2"] && s.a.items.count == 1)
    #expect(s.j.jqls[0].contains(#"key in ("SE-2")"#))
    #expect(try s.store.cursor(job: 1) == "")
}

@Test func cancelled() async {
    let s = Setup()
    let task = Task { await s.sync() }
    task.cancel()
    let run = await task.value
    #expect(run.error == "Cancelled" && s.a.items.isEmpty)
}

@Test func customRules() async {
    let s = Setup()
    s.j.issues[0].raw["issuetype"] = ["name": "Bug", "subtask": false]
    s.j.issues[0].raw["status"] = ["name": "QA"]
    s.j.issues[0].raw["priority"] = ["name": "Blocker"]
    var c = conn
    c.rules = Rules(types: ["bug": "Bug"], states: ["qa": "Verify Test"], priorities: ["Blocker": "1"])
    let it = s.a.items[await s.sync(conn: c).tickets[0].adoID]!
    #expect(it.type == "Bug" && it.fields[Field.state] as? String == "Verify Test" && it.fields[Field.priority] as? String == "1")
    #expect(c.rules.orDefault().state("Bug", "Weird") == "New")
}

@Test func jqlTimeZone() async {
    let cursor = Date(timeIntervalSince1970: 1_791_962_089)  // 2026-10-14 07:14:49 UTC
    let sg = TimeZone(identifier: "Asia/Singapore")!
    #expect(jqlTime(cursor, sg) == "2026/10/14 15:14")
    #expect(jqlTime(cursor, nil) == "2026/10/13 19:14")
    let s = Setup()
    s.j.zone = sg
    _ = await s.sync()
    _ = await s.sync()
    #expect(s.j.jqls.contains { $0.hasPrefix(#"updated >= "2026/10/14 17:00""#) })
}

@Test func unchangedItemsGetNoWrites() async {
    let s = Setup()
    let first = await s.sync()
    let pbi = first.tickets[0].adoID, task = first.tickets[1].adoID
    let patches = s.a.items[pbi]!.patches + s.a.items[task]!.patches, finds = s.a.finds
    let run = await s.sync()
    #expect(run.count(.skipped) == 2 && run.tickets[0].message.contains("already up to date"))
    #expect(s.a.items[pbi]!.patches + s.a.items[task]!.patches == patches)
    #expect(s.a.finds - finds == 2, "the sub-task's parent comes from the run's cache")

    s.j.issues[0].raw["summary"] = "renamed"
    let renamed = await s.sync()
    #expect(renamed.tickets[0].outcome == .updated && s.a.items[pbi]!.fields[Field.title] as? String == "SE-1 - 10 - renamed")
}

@Test func attachmentsLeftAloneWhenJiraHasNone() async {
    let s = Setup()
    let id = await s.sync().tickets[0].adoID
    s.a.items[id]!.attached = ["added-in-ado.png"]
    _ = await s.sync()
    #expect(s.a.items[id]!.attached.count == 1)
}

@Test func detailsFetchedInBatches() async {
    let s = Setup()
    _ = await s.sync()
    #expect(s.j.jqls.filter { $0.hasPrefix("id = ") }.isEmpty)
    #expect(s.j.jqls.filter { $0.hasPrefix("id in (10,11) AND project") }.count == 1)
}

@Test func notConfigured() async {
    let s = Setup()
    let run = await s.sync(conn: Connection(adoOrg: "org", pat: "p"))
    #expect(run.status == .failed && run.error.contains("Jira URL"))
}

@Test func checkpoint() {
    let i = { (id: String, u: String) in JiraIssue(id: id, key: id, fields: ["updated": u]) }
    let cp = Checkpoint([i("parent", "2026-10-03T00:00:00.000+0000"), i("old-sub", "2026-10-01T00:00:00.000+0000"), i("mid", "2026-10-02T00:00:00.000+0000")])
    #expect(cp.advance("parent") == nil)
    #expect(cp.advance("old-sub") == "2026-10-01T00:00:00.000+0000")
    #expect(cp.advance("mid") == "2026-10-03T00:00:00.000+0000")
}

@Test(arguments: [("2026-06-01", 63), ("2026-06-07", 63), ("2026-06-08", 64), ("2026-10-14", 82), ("2026-05-31", 62)])
func sprintNumbers(day: String, want: Int) {
    #expect(sprintNumber(anchor: 63, anchorDate: "2026-06-01", at: parseDay(day)!.addingTimeInterval(15 * 3600)) == want)
}

@Test func adf() {
    let doc = parseJSON(Data(#"""
        {"type":"doc","content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"T"}]},
        {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[
        {"type":"text","text":"go","marks":[{"type":"link","attrs":{"href":"https://x?a=1&b=2"}}]},{"type":"hardBreak"},
        {"type":"mention","attrs":{"text":"@Ana"}}]}]}]},{"type":"mediaSingle","content":[{"type":"media"}]}]}
        """#.utf8))
    #expect(adfToHTML(doc) == #"<h2>T</h2><ul><li><p><a href="https://x?a=1&amp;b=2">go</a><br/>@Ana</p></li></ul>"#)
}

@Test func changedOpsKeepsOnlyDifferences() {
    let cur: JSONObject = [Field.assignedTo: ["uniqueName": "Dev@ado.example"], Field.priority: NSNumber(value: 2),
                           Field.startDate: "2026-10-01T03:00:00Z", Field.description: "<p>a<br/></p>", Field.area: "tickets\\kpl"]
    let ops = [(Field.assignedTo, "dev@ado.example"), (Field.priority, "2"), (Field.startDate, "2026-10-01T10:00:00.000+0700"),
               (Field.description, "<p>a<br></p>"), (Field.area, "Tickets\\KPL"), (Field.title, "new")]
        .map { PatchOp(op: "add", path: "/fields/" + $0.0, value: $0.1) }
    #expect(changedOps(ops, cur).map(\.path) == ["/fields/" + Field.title])
}

@Test func fakeEngineSeeds() async {
    let s = Store(now: { t0 })
    await FakeEngine(delay: 0, now: { t0 }).seed(s)
    #expect(s.jobs.count == 3 && s.runs.count == 6 && s.job(3)?.status == .paused)
}
