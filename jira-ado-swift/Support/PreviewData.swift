import SwiftUI

/// Sample data for #Preview: a signed-in model over an in-memory store with three jobs and their runs, built synchronously for #Preview.
@MainActor
enum PreviewData {
    static let now = Date()

    static func model(signedIn: Bool = true, empty: Bool = false, live: Bool = false) -> AppModel {
        let store = Store(now: { now.addingTimeInterval(-7 * 86400) })
        let model = AppModel(store: store, engine: FakeEngine(delay: 0.5), secrets: .memory(), notifier: SilentNotifier())
        model.secretsLoaded = true
        model.pat = signedIn ? "preview-pat-preview-pat" : ""
        store.setSetting(Setting.adoOrg, "ats-technology")
        store.setSetting(Setting.adoUser, "Quan Nguyen Hong")
        store.setSetting(Setting.jiraURL, "https://keppel-ltd.atlassian.net")
        guard !empty else { return model }
        let mobile = store.addJob(job("Mobile bugs → ADO", "SE", "kai-mobile", .manual, users: [UserPair(jira: "dev@kai.example", adoEmail: "dev@ado.example")]))
        var webFilters = Filters()
        webFilters.autoPaths = false
        webFilters.iteration = #"kai-web\Sprint 42"#
        webFilters.everyMinutes = 180
        let web = store.addJob(job("Web platform stories", "WEB", "kai-web", .scheduler, filters: webFilters))
        let support = store.addJob(job("Support escalations", "SUP", "kai-support", .webhook))
        store.setStatus(support, .paused)
        store.addRun(run(web, hoursAgo: 30, [ticket("WEB-12", "Sprint report export is empty", .updated, id: 3012)]))
        store.addRun(run(mobile, hoursAgo: 26, [ticket("SE-101", "Login button unresponsive on Android", .created, id: 4101)], kind: .dryRun))
        store.addRun(run(mobile, hoursAgo: 3, [
            ticket("SE-101", "Login button unresponsive on Android", .updated, id: 4101),
            ticket("SE-102", "Fix tap target", .created, id: 4102, parent: "SE-101"),
            ticket("SE-103", "Add regression test", .skipped, parent: "SE-101", message: "ADO #4103 already up to date"),
            ticket("SE-140", "Crash when opening notifications", .failed, error: "TF401320: Rule Error for field Assigned To."),
            ticket("SE-151", "Sub-task of an earlier parent", .created, id: 4151, parent: "SE-90"),
        ]))
        store.addRun(run(web, hoursAgo: 1, [], error: "Preflight: Iteration path \"kai-web\\\\Sprint 42\" doesn't exist in ADO project kai-web. Nothing was written."))
        if live {
            model.syncNow(mobile)
        }
        model.catalog = CatalogState(cat: Catalog(
            jiraTypes: ["Story", "Bug", "Task", "Sub-task"], jiraStatuses: ["To Do", "In Progress", "In Review", "Done"],
            jiraPriorities: ["Highest", "High", "Medium", "Low"], adoTypes: ["Bug", typePBI, typeTask],
            adoStates: [typePBI: ["New", "Committed", "Done"], typeTask: ["To Do", "In Progress", "Done"]]), tried: true)
        return model
    }

    static var job: Job { model().store.jobs[0] }

    static func job(_ name: String, _ key: String, _ project: String, _ type: SyncType, users: [UserPair] = [], filters: Filters? = nil) -> Job {
        var f = filters ?? Filters()
        f.users = users
        return Job(name: name, jiraKey: key, adoProject: project, type: type, mappings: Field.supported, filters: f)
    }

    static func run(_ job: Int, hoursAgo: Double, _ tickets: [Ticket], kind: RunKind = .sync, error: String = "") -> Run {
        Run(jobID: job, started: now.addingTimeInterval(-hoursAgo * 3600), duration: 4.2, since: "2026-10-14T08:16:58Z", error: error, kind: kind, tickets: tickets)
    }

    static func ticket(_ key: String, _ summary: String, _ outcome: Outcome, id: Int = 0, parent: String = "", message: String = "", error: String = "") -> Ticket {
        let ops = #"[{"op":"add","path":"/fields/System.Title","value":"\#(key) - \#(summary)"},{"op":"add","path":"/fields/System.State","value":"In Progress"}]"#
        let calls = outcome == .skipped ? [] : [
            APICall(method: "POST", url: "https://dev.azure.com/ats-technology/kai/_apis/wit/wiql?api-version=7.1-preview", request: "{}", status: 200, response: #"{"workItems":[]}"#, duration: 0.21),
            APICall(method: outcome == .created ? "POST" : "PATCH", url: "https://dev.azure.com/ats-technology/kai/_apis/wit/workitems/\(id)?api-version=7.1-preview",
                    request: ops, status: outcome == .failed ? 400 : 200, response: outcome == .failed ? #"{"message":"TF401320"}"# : #"{"id":\#(id)}"#,
                    retries: outcome == .failed ? 1 : 0, duration: 0.48, error: outcome == .failed ? "HTTP 400" : ""),
        ]
        return Ticket(key: key, summary: summary, parentKey: parent, outcome: outcome, workItemType: parent.isEmpty ? typePBI : typeTask, adoID: id,
                      message: message.isEmpty && outcome != .failed ? "\(outcome.rawValue.capitalized) ADO #\(id)" : message, error: error, calls: calls)
    }
}

extension View {
    /// The environment every page expects, over preview data.
    func previewModel(_ model: AppModel? = nil) -> some View { environment(model ?? PreviewData.model()) }
}
