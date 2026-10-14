import Foundation
import Testing
@testable import JirAdo

@Test func sqliteRoundTrip() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("jira-ado-\(UUID()).db").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var s: Store? = try Store(path: path, now: { t0 })
    let id = s!.addJob(Job(name: "Mobile", jiraKey: "SE", adoProject: "kai", mappings: Field.supported))
    s!.setStatus(id, .paused)
    let rid = s!.addRun(Run(jobID: id, started: t0, duration: 1.5, kind: .dryRun,
                            tickets: [Ticket(key: "SE-1", outcome: .failed, error: "boom", calls: [APICall(method: "POST", status: 400)])]))
    s!.setRules(Rules(priorities: ["Blocker": "1"]))
    try s!.setCursor(job: id, "2026-10-14T09:00:00Z")
    s = nil

    let back = try Store(path: path)
    #expect(back.job(id)?.status == .paused && back.job(id)?.mappings == Field.supported && back.job(id)?.activity.count == 2)
    #expect(back.run(rid)?.tickets.first?.calls.first?.status == 400 && back.run(rid)?.duration == 1.5)
    #expect(back.lastRun(id) == nil, "dry runs don't count as the last run")
    #expect(back.rules.priority("blocker") == "1" && back.rules.priority("High") == "4")
    #expect(try back.cursor(job: id) == "2026-10-14T09:00:00Z")
    back.deleteJob(id)
    #expect(try Store(path: path).runs.isEmpty, "deleting a job cascades to its runs")
}

@Test func inMemoryStoreJobsAndRuns() throws {
    var clock = t0
    let s = Store(now: { clock })
    let id = s.addJob(Job(name: "A", jiraKey: "SE", status: .paused))
    #expect(s.job(id)?.status == .active, "new jobs start active")
    #expect(s.job(id)?.created == t0 && s.job(id)?.activity.map(\.text) == ["Job created"])

    clock = t0.addingTimeInterval(60)
    var edit = s.job(id)!
    edit.name = "B"
    edit.jiraKey = "OTHER"
    s.updateJob(edit)
    #expect(s.job(id)?.name == "B" && s.job(id)?.jiraKey == "SE", "the Jira key is fixed after creation")
    s.setStatus(id, .paused)
    s.setStatus(id, .paused)  // no change, no activity
    s.log(id, "note")
    #expect(s.job(id)?.activity.map(\.text) == ["Job created", "Job settings changed", "Job paused", "note"])

    let r1 = s.addRun(Run(jobID: id, started: t0)), r2 = s.addRun(Run(jobID: id, started: t0, kind: .dryRun))
    #expect(s.runs.map(\.id) == [r2, r1], "newest first")
    #expect(s.lastRun(id)?.id == r1 && s.runs(for: id).count == 2)
    s.deleteRuns([r1])
    #expect(s.run(r1) == nil && s.lastRun(id) == nil)
    s.deleteJob(id)
    #expect(s.jobs.isEmpty && s.runs.isEmpty)
}

@Test func settingsRulesAndSharedUsers() {
    let s = Store()
    #expect(s.rules == Rules.defaults && s.sharedUsers.isEmpty)
    s.setSetting(Setting.rules, "{broken")
    #expect(s.rules == Rules.defaults, "a broken value means the defaults")
    s.setSharedUsers([UserPair(jira: "a", adoEmail: "a@x")])
    #expect(s.sharedUsers == [UserPair(jira: "a", adoEmail: "a@x")])
}

@Test func syncStateInMemory() throws {
    let s = Store()
    #expect(try s.cursor(job: 1) == "")
    try s.setCursor(job: 1, "c")
    let m = CommentMapping(workItemID: 9, jiraCommentID: "c1", adoCommentID: 3, jiraUpdated: "u")
    try s.saveCommentMapping(m)
    #expect(try s.cursor(job: 1) == "c" && s.commentMappings(workItem: 9) == ["c1": m] && s.commentMappings(workItem: 8).isEmpty)
    let ro = ReadOnlyState(base: s)
    try ro.setCursor(job: 1, "moved")
    try ro.saveCommentMapping(CommentMapping(workItemID: 9, jiraCommentID: "c2", adoCommentID: 4, jiraUpdated: "u"))
    #expect(try s.cursor(job: 1) == "c" && s.commentMappings(workItem: 9).count == 1, "a dry run's state never writes")
}

@Test func sqliteCommentMappingsUpsert() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("jira-ado-\(UUID()).db").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let s = try Store(path: path)
    try s.saveCommentMapping(CommentMapping(workItemID: 1, jiraCommentID: "c", adoCommentID: 2, jiraUpdated: "u1"))
    try s.saveCommentMapping(CommentMapping(workItemID: 1, jiraCommentID: "c", adoCommentID: 2, jiraUpdated: "u2"))
    #expect(try s.commentMappings(workItem: 1)["c"]?.jiraUpdated == "u2")
    s.setSetting(Setting.theme, "dark")
    #expect(try Store(path: path).settings[Setting.theme] == "dark")
}

@Test func databaseTransactionRollsBack() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("db-\(UUID()).db").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try Database(path: path)
    try db.exec("CREATE TABLE t (v TEXT NOT NULL)")
    #expect(throws: (any Error).self) { try db.transaction([("INSERT INTO t VALUES (?)", ["ok"]), ("INSERT INTO t VALUES (?)", [nil])]) }
    #expect(try db.query("SELECT COUNT(*) FROM t").first?.first as? Int64 == 0)
    try db.exec("INSERT INTO t VALUES (?)", 1.5)
    #expect(try db.query("SELECT v FROM t").first?.first as? String == "1.5")
}

@Test func saveErrorsAreReported() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("ro-\(UUID()).db").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let s = try Store(path: path)
    try Database(path: path).exec("DROP TABLE settings")
    var reported: Error?
    s.onSaveError = { reported = $0 }
    s.setSetting("k", "v")
    #expect(reported != nil && s.settings["k"] == "v", "memory keeps the change")
}

@Test func removedSyncTypesLoadAsManual() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("wh-\(UUID()).db").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let id = try Store(path: path).addJob(Job(name: "Old", jiraKey: "OLD"))
    try Database(path: path).exec("UPDATE jobs SET type = 'Webhook' WHERE id = ?", id)
    #expect(try Store(path: path).job(id)?.type == .manual)
}
