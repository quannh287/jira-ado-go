import Foundation
import Testing
@testable import jira_ado

/// Builds a database the way the Go app (schema v4) left it, Go field names in the JSON columns.
func makeGoDatabase(jobKey: String = "CAT", runs: [(started: Int64, kind: String)] = [(1_791_969_074_090, "")],
                    cursor: String = "2026-10-14T08:16:58.084992Z", comments: [(Int, String, Int, String)] = [(11, "c1", 5, "u1")]) throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("go-\(UUID()).db").path
    let db = try Database(path: path)
    for sql in [
        "CREATE TABLE jobs (id INTEGER PRIMARY KEY, name TEXT NOT NULL, jira_key TEXT NOT NULL, ado_project TEXT NOT NULL, type TEXT NOT NULL, status TEXT NOT NULL, created INTEGER NOT NULL, mappings TEXT NOT NULL, filters TEXT NOT NULL)",
        "CREATE TABLE job_activity (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, at INTEGER NOT NULL, text TEXT NOT NULL)",
        "CREATE TABLE runs (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, started INTEGER NOT NULL, duration_ms INTEGER NOT NULL, since TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT '')",
        "CREATE TABLE tickets (id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, key TEXT NOT NULL, summary TEXT NOT NULL, outcome TEXT NOT NULL, error TEXT NOT NULL, calls TEXT NOT NULL, work_item_type TEXT NOT NULL DEFAULT '', ado_id INTEGER NOT NULL DEFAULT 0, message TEXT NOT NULL DEFAULT '', parent_key TEXT NOT NULL DEFAULT '')",
        "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "CREATE TABLE sync_state (job_id INTEGER PRIMARY KEY, cursor TEXT NOT NULL)",
        "CREATE TABLE comment_mappings (ado_work_item_id INTEGER NOT NULL, jira_comment_id TEXT NOT NULL, ado_comment_id INTEGER NOT NULL, jira_updated TEXT NOT NULL, PRIMARY KEY (ado_work_item_id, jira_comment_id))",
        "PRAGMA user_version = 4",
    ] { try db.exec(sql) }
    try db.exec("INSERT INTO jobs VALUES (7, 'Jira -> ADO (CAT)', ?, 'Tickets', 'Scheduler', 'ACTIVE', 1791960000000, ?, ?)", jobKey,
                #"[{"Jira":"summary","ADO":"System.Title"},{"Jira":"status","ADO":"System.State"}]"#,
                #"{"SyncComments":true,"UserFilter":true,"Assignees":"Quan","Users":[{"Jira":"Quan","ADOEmail":"quan@x.io"}],"AreaPath":"Tickets\\KPL\\KAI","AutoPaths":true,"Iteration":"","SprintRoot":"Tickets\\Weekly Sprint","AnchorSprint":82,"AnchorDate":"2026-10-14","EveryMinutes":360}"#)
    try db.exec("INSERT INTO job_activity (job_id, at, text) VALUES (7, 1791960000000, 'Job created')")
    for (i, r) in runs.enumerated() {
        try db.exec("INSERT INTO runs VALUES (?, 7, ?, 1500, '', '', ?)", 30 + i, r.started, r.kind)
        try db.exec("INSERT INTO tickets (run_id, key, summary, outcome, error, calls, work_item_type, ado_id, message, parent_key) VALUES (?, 'CAT-2', 'Sub', 'failed', 'boom', ?, 'Task', 12, 'msg', 'CAT-1')",
                    30 + i, #"[{"Method":"POST","URL":"u","Request":"{}","Status":400,"Response":"r","Retries":1,"Duration":1500000000,"Error":"boom"}]"#)
    }
    try db.exec("INSERT INTO sync_state VALUES (7, ?)", cursor)
    for c in comments { try db.exec("INSERT INTO comment_mappings VALUES (?, ?, ?, ?)", c.0, c.1, c.2, c.3) }
    for (k, v) in [(Setting.adoOrg, "ats-technology"), (Setting.theme, "dark"), (Setting.notify, "failures"),
                   (Setting.sharedUsers, #"[{"Jira":"a@x.io","ADOEmail":"a@ado.io"}]"#),
                   (Setting.rules, #"{"Types":null,"SubtaskType":"Task","DefaultType":"Product Backlog Item","States":{"QA":"Verify Test"},"TaskStates":null,"Priorities":{"Blocker":"1"}}"#)] {
        try db.exec("INSERT INTO settings VALUES (?, ?)", k, v)
    }
    return path
}

@Suite struct LegacyImportTests {
    @Test func readsTheGoSchema() throws {
        let path = try makeGoDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let snap = try LegacySnapshot(path: path)
        let j = try #require(snap.jobs.first)
        #expect(j.name == "Jira -> ADO (CAT)" && j.type == .scheduler && j.mappings.map(\.ado) == [Field.title, Field.state])
        #expect(j.filters.everyMinutes == 360 && j.filters.anchorSprint == 82 && j.filters.areaPath == #"Tickets\KPL\KAI"# && j.filters.users.first?.adoEmail == "quan@x.io")
        #expect(j.activity.map(\.text) == ["Job created"])
        let t = try #require(snap.runs.first?.tickets.first)
        #expect(t.parentKey == "CAT-1" && t.adoID == 12 && t.outcome == .failed && t.calls.first?.duration == 1.5 && t.calls.first?.retries == 1)
        #expect(snap.cursors == [7: "2026-10-14T08:16:58.084992Z"] && snap.comments.count == 1)
        let rules = try #require(snap.settings[Setting.rules].map { (try decode($0) as Rules) })
        #expect(rules.states == ["QA": "Verify Test"] && rules.priorities == ["Blocker": "1"] && rules.types.isEmpty)
        #expect(try (decode(snap.settings[Setting.sharedUsers]!) as [UserPair]) == [UserPair(jira: "a@x.io", adoEmail: "a@ado.io")])
    }

    @Test func importsNewestAndMergesCommentLinks() throws {
        let prod = try makeGoDatabase(runs: [(1_791_969_074_090, ""), (1_791_969_100_000, "dry-run")], comments: [(11, "c1", 5, "u2")])
        let dev = try makeGoDatabase(runs: [(1_791_963_723_111, "")], cursor: "older", comments: [(11, "c1", 5, "u1"), (12, "c9", 6, "u1")])
        defer { for p in [prod, dev] { try? FileManager.default.removeItem(atPath: p) } }
        let store = Store()
        store.addJob(Job(name: "Other", jiraKey: "WEB"))
        let summary = try store.importLegacy([try LegacySnapshot(path: dev), try LegacySnapshot(path: prod)])
        #expect(summary == Store.ImportSummary(jobs: 1, runs: 2, comments: 2, cursors: 1))
        let j = try #require(store.jobs.last)
        #expect(j.id == 2 && j.jiraKey == "CAT" && store.runs(for: 2).count == 2, "renumbered after the store's own")
        #expect(try store.cursor(job: 2) == "2026-10-14T08:16:58.084992Z", "the newest database wins")
        #expect(try store.commentMappings(workItem: 11)["c1"]?.jiraUpdated == "u2" && store.commentMappings(workItem: 12).count == 1)
        #expect(store.settings[Setting.theme] == "dark" && store.rules.priority("Blocker") == "1")
        #expect(summary.text == "Imported 1 job, 2 runs, 2 comment links and 1 cursor")
    }

    @Test func refusesASecondJobForTheSameProject() throws {
        let path = try makeGoDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = Store()
        store.addJob(Job(name: "Mine", jiraKey: "CAT"))
        #expect(throws: Failure.self) { try store.importLegacy([try LegacySnapshot(path: path)]) }
        #expect(store.jobs.count == 1 && store.runs.isEmpty)
    }

    @Test func persistsAndLeavesTheSourceUntouched() throws {
        let src = try makeGoDatabase()
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("swift-\(UUID()).db").path
        defer { for p in [src, dst] { try? FileManager.default.removeItem(atPath: p) } }
        let before = try Data(contentsOf: URL(fileURLWithPath: src))
        _ = try Store(path: dst).importLegacy([try LegacySnapshot(path: src)])
        let reopened = try Store(path: dst)
        #expect(reopened.jobs.first?.jiraKey == "CAT" && reopened.runs.first?.tickets.first?.calls.first?.status == 400)
        #expect(try reopened.cursor(job: 1) != "" && reopened.commentMappings(workItem: 11).count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: src)) == before, "the Go app's file is opened read-only")
    }

    @Test func rejectsOtherFiles() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID()).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try Database(path: path)
        #expect(throws: Failure.self) { try LegacySnapshot(path: path) }
        #expect(throws: (any Error).self) { try LegacySnapshot(path: "/nonexistent/x.db") }
    }

    @Test func modelImportShowsSummaryOrError() throws {
        let path = try makeGoDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let h = Harness()
        h.model.importLegacy([URL(fileURLWithPath: path)])
        #expect(h.model.notice?.hasPrefix("Imported 1 job") == true)
        h.model.importLegacy([URL(fileURLWithPath: path)])
        #expect(h.model.notice?.hasPrefix("Import failed: A job for Jira project CAT already exists") == true)
    }
}
