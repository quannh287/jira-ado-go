import Foundation
import Testing
@testable import jira_ado_swift

final class RecordingNotifier: Notifier {
    var sent: [(id: String, title: String, subtitle: String, body: String)] = []
    func notify(id: String, title: String, subtitle: String, body: String) { sent.append((id, title, subtitle, body)) }
}

/// An engine whose runs fail tickets on demand, to drive the model's run handling.
final class ScriptedEngine: SyncEngine {
    var tickets: [Ticket] = [Ticket(key: "SE-1", outcome: .created)]
    var runError = ""
    var validName: String?  // nil: the PAT is rejected
    var gate: CheckedContinuation<Void, Never>?
    var block = false
    var syncs: [(job: Job, opts: RunOptions)] = []
    var started = t0

    func validatePAT(org: String, pat: String) async throws -> String {
        guard let validName else { throw Failure("ADO rejected the personal access token") }
        return validName
    }
    func checkJira(_ conn: Connection) async throws -> String { "Jira Me" }
    func check(_ conn: Connection, _ job: Job) async throws -> [String] { [] }
    func catalog(_ conn: Connection, jiraProjects: [String], adoProjects: [String]) async -> (Catalog, String?) {
        (Catalog(jiraTypes: jiraProjects, adoTypes: adoProjects), nil)
    }

    func sync(_ conn: Connection, _ job: Job, _ opts: RunOptions) async -> Run {
        syncs.append((job, opts))
        var run = Run(jobID: job.id, started: started, kind: opts.dryRun ? .dryRun : opts.keys.isEmpty ? .sync : .retry)
        opts.onProgress?(SyncProgress(run: run, done: 0, total: tickets.count))
        if block { await withCheckedContinuation { gate = $0 } }
        if Task.isCancelled { run.error = "Cancelled"; return run }
        run.tickets = tickets
        run.error = runError
        return run
    }
}

struct Harness {
    let model: AppModel
    let engine = ScriptedEngine()
    let notifier = RecordingNotifier()
    let secrets = Secrets.memory()
    var badges: [Int] = []
    let jobID: Int

    init(pat: String = "pat-pat-pat-pat-pat-pat") {
        let store = Store(now: { t0 })
        jobID = store.addJob(Job(name: "Mobile", jiraKey: "SE", adoProject: "kai", mappings: Field.supported))
        model = AppModel(store: store, engine: engine, secrets: secrets, notifier: notifier)
        model.now = { t0 }
        model.pat = pat
    }
}

@Suite struct AppModelTests {
    @Test func syncSavesRunLogsAndNotifies() async {
        let h = Harness()
        var badge: [Int] = []
        h.model.badge = { badge.append($0) }
        await h.model.syncNow(h.jobID)?.value
        let run = h.model.store.lastRun(h.jobID)
        #expect(run?.count(.created) == 1 && h.model.running.isEmpty && h.model.live.isEmpty)
        #expect(h.model.store.job(h.jobID)?.activity.map(\.text).suffix(2) == ["Sync started", "Sync 1 created, 0 updated, 0 skipped, 0 failed"])
        #expect(h.notifier.sent.first?.id == "run/\(h.jobID)/\(run!.id)" && h.notifier.sent.first?.subtitle == "Sync finished")
        #expect(h.model.notice == "Mobile: 1 created, 0 updated, 0 skipped, 0 failed")
        #expect(badge == [0])
    }

    @Test func runsUseTheEffectiveJobAndConnection() async {
        let h = Harness()
        h.model.store.setSharedUsers([UserPair(jira: "shared", adoEmail: "s@x.io")])
        var j = h.model.store.job(h.jobID)!
        j.filters.users = [UserPair(jira: "own", adoEmail: "o@x.io")]
        h.model.store.updateJob(j)
        h.model.store.setSetting(Setting.jiraURL, "https://site")
        await h.model.syncNow(h.jobID)?.value
        #expect(h.engine.syncs[0].job.filters.users.map(\.jira) == ["own", "shared"], "the job's own mapping wins")
        let c = h.model.connection()
        #expect(c.jiraURL == "https://site" && c.pat == h.model.pat && c.rules == Rules.defaults)
    }

    @Test func pausedRunningOrMissingJobsDontStart() async {
        let h = Harness()
        #expect(h.model.syncNow(999) == nil)
        h.model.store.setStatus(h.jobID, .paused)
        #expect(h.model.syncNow(h.jobID) == nil)
        h.model.store.setStatus(h.jobID, .active)
        h.engine.block = true
        let task = h.model.syncNow(h.jobID)
        await Task.yield()
        #expect(h.model.running == [h.jobID] && h.model.live[h.jobID] != nil)
        #expect(h.model.dryRun(h.jobID) == nil, "one run per job at a time")
        h.engine.gate?.resume()
        await task?.value
        #expect(h.model.running.isEmpty)
    }

    @Test func cancelStopsTheRun() async {
        let h = Harness()
        h.engine.block = true
        let task = h.model.syncNow(h.jobID)
        await Task.yield()
        h.model.cancelRun(h.jobID)
        h.engine.gate?.resume()
        await task?.value
        #expect(h.model.store.lastRun(h.jobID)?.error == "Cancelled")
        #expect(h.model.store.job(h.jobID)?.activity.contains { $0.text == "Cancel requested" } == true)
    }

    @Test func runOfDeletedJobIsDropped() async {
        let h = Harness()
        h.engine.block = true
        let task = h.model.syncNow(h.jobID)
        await Task.yield()
        h.model.store.deleteJob(h.jobID)
        h.engine.gate?.resume()
        await task?.value
        #expect(h.model.store.runs.isEmpty && h.notifier.sent.isEmpty)
    }

    @Test func liveReportIsReplacedBySavedRun() async {
        let h = Harness()
        h.model.openReport(h.jobID, run: nil)
        await h.model.syncNow(h.jobID)?.value
        #expect(h.model.path.last == .report(h.jobID, runID: h.model.store.lastRun(h.jobID)!.id))
    }

    @Test func dryRunAndRetryKinds() async {
        let h = Harness()
        h.engine.tickets = [Ticket(key: "SE-1", outcome: .failed), Ticket(key: "SE-2", outcome: .failed)]
        await h.model.dryRun(h.jobID)?.value
        #expect(h.engine.syncs[0].opts.dryRun && h.model.store.lastRun(h.jobID) == nil, "dry runs aren't the last run")
        await h.model.syncNow(h.jobID)?.value
        let failed = h.model.store.lastRun(h.jobID)!
        #expect(h.model.retryFailed(Run()) == nil)
        await h.model.retryFailed(failed)?.value
        #expect(h.engine.syncs[2].opts.keys == ["SE-1", "SE-2"])
        #expect(h.model.store.job(h.jobID)?.activity.contains { $0.text == "Retry of 2 failed tickets started" } == true)
    }

    @Test(arguments: [(NotifyMode.all, false, 1), (.all, true, 1), (.failures, false, 0), (.failures, true, 1), (.off, true, 0)])
    func notifyModes(mode: NotifyMode, failing: Bool, sent: Int) async {
        let h = Harness()
        h.model.store.setSetting(Setting.notify, mode.rawValue)
        if failing { h.engine.tickets = (1...5).map { Ticket(key: "SE-\($0)", outcome: .failed) } }
        await h.model.syncNow(h.jobID)?.value
        #expect(h.notifier.sent.count == sent)
        if failing && sent > 0 {
            #expect(h.notifier.sent[0].subtitle == "Sync finished with failures")
            #expect(h.notifier.sent[0].body.hasSuffix("Failed: SE-1, SE-2, SE-3 +2"))
        }
    }

    @Test func runErrorNotification() async {
        let h = Harness()
        h.engine.runError = "Not configured: Jira URL (Settings)"
        await h.model.dryRun(h.jobID)?.value
        #expect(h.notifier.sent[0].subtitle == "Dry run failed" && h.notifier.sent[0].body == h.engine.runError)
        #expect(h.model.notice == "Mobile: failed: Not configured: Jira URL (Settings)")
    }

    @Test func openNotificationRoutes() async {
        let h = Harness()
        await h.model.syncNow(h.jobID)?.value
        let rid = h.model.store.lastRun(h.jobID)!.id
        h.model.openNotification(notificationID(h.jobID, rid))
        #expect(h.model.section == .jobs && h.model.path == [.job(h.jobID), .report(h.jobID, runID: rid)])
        h.model.openNotification(notificationID(h.jobID, 999))
        #expect(h.model.path == [.job(h.jobID)], "a deleted run opens its job")
        h.model.openNotification(AppModel.testNotificationID)
        #expect(h.model.section == .settings && h.model.path.isEmpty)
        h.model.openNotification("run/999/1")
        #expect(h.model.section == .dashboard)
    }

    @Test func tickStartsDueSchedulerJobsOnly() async {
        let h = Harness()
        var j = h.model.store.job(h.jobID)!
        j.type = .scheduler
        j.filters.everyMinutes = 30
        h.model.store.updateJob(j)
        h.model.now = { t0.addingTimeInterval(29 * 60) }
        h.model.tick()
        #expect(h.engine.syncs.isEmpty, "not due yet: counted from creation")
        h.model.now = { t0.addingTimeInterval(30 * 60) }
        h.engine.started = t0.addingTimeInterval(30 * 60)
        h.model.tick()
        await Task.yield()
        #expect(h.model.running.contains(h.jobID) || h.engine.syncs.count == 1)
        while !h.model.running.isEmpty { await Task.yield() }
        h.model.tick()
        await Task.yield()
        #expect(h.engine.syncs.count == 1, "the run just finished resets the interval")
    }

    @Test func tickDoesNothingSignedOut() {
        let h = Harness(pat: "")
        var j = h.model.store.job(h.jobID)!
        j.type = .scheduler
        h.model.store.updateJob(j)
        h.model.now = { t0.addingTimeInterval(86400) }
        h.model.tick()
        #expect(h.engine.syncs.isEmpty)
    }

    @Test func badgeCountsJobsWhoseLastRunFailed() async {
        let h = Harness()
        var badge: [Int] = []
        h.model.badge = { badge.append($0) }
        h.engine.tickets = [Ticket(outcome: .failed)]
        await h.model.syncNow(h.jobID)?.value
        h.model.store.addJob(Job(name: "Never ran"))
        h.model.updateBadge()
        #expect(badge == [1, 1])
    }

    @Test func signInStoresPATWhenRemembered() async throws {
        let h = Harness(pat: "")
        h.engine.validName = "Quan"
        await h.model.signIn(org: " my-org ", pat: " secret ", remember: true)
        #expect(h.model.pat == "secret" && h.model.remember && h.model.loginError.isEmpty)
        #expect(try h.secrets.pat.get() == "secret")
        #expect(h.model.setting(Setting.adoOrg) == "my-org" && h.model.setting(Setting.adoUser) == "Quan")

        await h.model.toggleRemember(false)
        #expect(try !h.model.remember && h.model.pat == "secret" && h.secrets.pat.get() == "")
        await h.model.logout()
        #expect(h.model.pat.isEmpty && h.model.section == .dashboard)
    }

    @Test func signInRejected() async {
        let h = Harness(pat: "")
        await h.model.signIn(org: "o", pat: "bad", remember: true)
        #expect(h.model.pat.isEmpty && h.model.loginError == "ADO rejected the personal access token")
    }

    @Test func loadSecretsAndSaveSettings() async throws {
        let h = Harness(pat: "")
        try h.secrets.pat.set("saved")
        try h.secrets.jira.set("jt")
        await h.model.loadSecrets()
        #expect(h.model.secretsLoaded && h.model.pat == "saved" && h.model.remember && h.model.jiraToken == "jt")

        await h.model.saveSettings(jiraURL: " https://site.test/// ", email: " me@x.io ", jql: " type = Bug ", keyField: "", token: " new ")
        #expect(h.model.setting(Setting.jiraURL) == "https://site.test" && h.model.setting(Setting.jiraEmail) == "me@x.io")
        #expect(try h.model.setting(Setting.jqlExtra) == "type = Bug" && h.model.jiraToken == "new" && h.secrets.jira.get() == "new")
        #expect(h.model.notice == "Settings saved")
    }

    @Test func navigation() {
        let h = Harness()
        h.model.openJob(h.jobID)
        #expect(h.model.section == .jobs && h.model.path == [.job(h.jobID)])
        h.model.open(.logs)
        #expect(h.model.section == .logs && h.model.path.isEmpty)
    }

    @Test func catalogLoadsForTheJobsProjects() async {
        let h = Harness()
        await h.model.loadCatalog()
        #expect(h.model.catalog.tried && !h.model.catalog.loading && h.model.catalog.cat.jiraTypes == ["SE"] && h.model.catalog.cat.adoTypes == ["kai"])
        h.model.store.deleteJob(h.jobID)
        await h.model.loadCatalog()
        #expect(h.model.catalog.error.hasPrefix("Create a sync job first"))
    }

    @Test func launchModes() {
        let tests = AppModel.launch(["XCTestConfigurationFilePath": "x"], [])
        #expect(tests.engine is FakeEngine && tests.store.jobs.isEmpty)
        let ui = AppModel.launch([:], ["app", LaunchArgument.uiTesting, LaunchArgument.signedIn])
        #expect(ui.engine is FakeEngine && ui.setting(Setting.adoOrg) == "demo-org")
    }

    @Test func appIconOptions() {
        #expect(AppIconOption.get(nil).id == AppIconOption.defaultID && AppIconOption.get("lanes").name == "Lane change")
        #expect(AppIconOption.all.allSatisfy { $0.image != nil }, "every icon is in the asset catalog")
    }
}

@Suite struct FakeEngineTests {
    @Test func fakeSyncAndCatalog() async throws {
        let f = FakeEngine(delay: 0, now: { t0 })
        let run = await f.sync(Connection(), Job(id: 1, jiraKey: "SE"), RunOptions(keys: ["SE-7", "SE-8"]))
        #expect(run.kind == .retry && run.tickets.map(\.key) == ["SE-7", "SE-8"])
        #expect(await f.catalog(Connection(), jiraProjects: [], adoProjects: []).0.adoStates[typeTask] != nil)
        await #expect(throws: Failure.self) { try await f.validatePAT(org: "o", pat: "short") }
        #expect(try await f.validatePAT(org: "o", pat: String(repeating: "x", count: 20)) == "Demo User")
        await #expect(throws: Failure.self) { try await f.checkJira(Connection()) }
    }
}
