import Foundation

/// The Sprint page: the live board, the day snapshots behind the chart, and whatever write is waiting for a yes.
struct SprintState {
    var board = SprintBoard()
    var days: [SprintDay] = []
    var loading = false
    var loaded = false
    var error = ""
    /// Non-empty while the confirm sheet is up; nothing has reached ADO yet.
    var pending: [SprintChange] = []
    var pendingTitle = ""
    var applying = false
    var selection: Set<Int> = []
    var outsideSelection: Set<Int> = []

    var committed: Double { committedHours(board.tasks) }
    /// Work pulled in after the sprint started is shown apart, so the Monday number stays readable.
    var planned: Double {
        guard let base = days.first else { return committed }
        let ids = Set(base.tasks.map(\.id))
        return committedHours(board.tasks.filter { ids.contains($0.id) })
    }
    var unplanned: Double { committed - planned }
    func committed(_ project: String) -> Double { committedHours(board.project(project)) }
}

extension AppModel {
    var sprintConfig: SprintConfig { store.sprintConfig }

    /// Nil until ADO is configured; building it per call keeps the PAT out of the model's stored state.
    func tracker() -> SprintTracker? {
        let c = store.sprintConfig
        guard c.configured, !pat.isEmpty else { return nil }
        let t = SprintTracker(config: c, org: setting(Setting.adoOrg), pat: pat, now: now)
        makeTracker?(t)
        return t
    }

    /// Reads ADO and records today's snapshot; the chart is read back from those, never from this one load.
    func loadSprint() async {
        guard let tracker = tracker() else {
            sprint.error = "Sign in and add a sprint project in Settings first."
            return
        }
        sprint.loading = true
        sprint.error = ""
        defer { sprint.loading = false }
        do {
            let board = try await tracker.load()
            sprint.board = board
            sprint.loaded = true
            sprint.error = board.errors.joined(separator: "\n")
            store.saveSnapshot(sprint: board.sprint.path, day: dayString(now()), tasks: board.tasks)
            store.setSetting(Setting.sprintLastSnapshot, dayString(now()))
            sprint.days = store.snapshots(sprint: board.sprint.path)
        } catch {
            sprint.error = describe(error)
            AppLog.error("sprint load", ["err": describe(error)])
        }
    }

    /// Puts changes in front of the user. An empty plan says so instead of opening an empty sheet.
    func proposeSprint(_ title: String, _ changes: [SprintChange]) {
        guard !changes.isEmpty else {
            show("\(title): nothing to change.")
            return
        }
        sprint.pendingTitle = title
        sprint.pending = changes
    }

    func cancelSprintChanges() {
        sprint.pending = []
        sprint.pendingTitle = ""
    }

    func applySprintChanges() async {
        guard let tracker = tracker() else { return }
        let changes = sprint.pending
        sprint.applying = true
        let errors = await tracker.apply(changes)
        sprint.applying = false
        cancelSprintChanges()
        sprint.selection = []
        sprint.outsideSelection = []
        // Numbers come from ADO, never from adding up the plan: a write that partly failed must not look applied.
        await loadSprint()
        show(errors.isEmpty ? "Wrote \(changes.count) change\(changes.count == 1 ? "" : "s") to ADO."
                            : "\(errors.count) of \(changes.count) failed: " + errors.joined(separator: "; "))
    }

    /// One snapshot a day, taken by the scheduler so the chart fills in even on days the page is never opened.
    var sprintSnapshotDue: Bool {
        store.sprintConfig.configured && !pat.isEmpty && setting(Setting.sprintLastSnapshot) != dayString(now())
    }
}
