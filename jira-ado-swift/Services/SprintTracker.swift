import Foundation

// Reads the weekly sprint from ADO and turns every write into a reviewable plan. The judgement calls — what the
// sub-tasks of a PBI should be, how long they take — stay with the planning skill; this only applies rules.

protocol SprintAPI {
    func wiql(_ query: String) async throws -> [Int]
    func batch(_ ids: [Int], fields: [String]) async throws -> [JSONObject]
    func iterations(under base: String) async throws -> [Iteration]
    func create(type: String, ops: [PatchOp]) async throws -> Int
    func update(_ id: Int, ops: [PatchOp]) async throws
    func parentRelation(_ parentID: Int) -> PatchOp
}

extension ADOClient: SprintAPI {}

/// One pending write. Nothing reaches ADO until the user confirms the list these build.
struct SprintChange: Identifiable {
    enum Kind {
        case update(Int)
        case create(parent: Int)
    }

    var kind: Kind
    var project = ""
    var title = ""
    var detail = ""  // what this does, one line, shown in the confirm sheet
    var ops: [PatchOp] = []

    var id: String {
        switch kind {
        case .update(let id): "u\(id)-\(detail)"
        case .create(let parent): "c\(parent)-\(title)"
        }
    }

    var workItem: Int? {
        if case .update(let id) = kind { return id }
        return nil
    }
}

/// A sprint as ADO has it right now: what is in it, and what of the user's work sits outside it.
struct SprintBoard {
    var sprint = Iteration()
    var iterations: [Iteration] = []
    var tasks: [SprintTask] = []
    var outside: [SprintTask] = []
    var errors: [String] = []

    var next: Iteration? { iterations.first { $0.start > sprint.start } }
    func project(_ name: String) -> [SprintTask] { tasks.filter { $0.project == name } }
    func children(_ id: Int) -> [SprintTask] { (tasks + outside).filter { $0.parentID == id } }
    func task(_ id: Int) -> SprintTask? { (tasks + outside).first { $0.id == id } }
}

@MainActor
final class SprintTracker {
    let config: SprintConfig
    let now: () -> Date
    /// Swapped in tests for a fake.
    var client: (SprintProject) -> SprintAPI

    private static let fields = [
        Field.title, Field.workItemType, Field.state, Field.originalEstimate, Field.completedWork,
        Field.priority, Field.dueDate, Field.parent, Field.iteration, Field.area,
    ]

    init(config: SprintConfig, org: String, pat: String, now: @escaping () -> Date = Date.init) {
        self.config = config
        self.now = now
        client = { ADOClient(org: org, project: $0.adoProject, pat: pat) }
    }

    // MARK: Reading

    /// Everything the page shows. A project that fails is reported and the rest still loads.
    func load() async throws -> SprintBoard {
        guard let first = config.projects.first else { throw Failure("add a project in Settings first") }
        var board = SprintBoard()
        board.iterations = try await client(first).iterations(under: first.iterationBase)
        guard let sprint = Self.current(board.iterations, at: now()) else { throw Failure("no sprint found under \(first.iterationBase)") }
        board.sprint = sprint

        for p in config.projects {
            do {
                let items = try await fetch(p)
                board.tasks += items.filter { $0.iteration == sprint.path }
                board.outside += items.filter { $0.iteration != sprint.path && !$0.done }
            } catch {
                board.errors.append("\(p.name): \(describe(error))")
                AppLog.warn("sprint fetch failed", ["project": p.name, "err": describe(error)])
            }
        }
        return board
    }

    /// The sprint holding t, else the next one to start — a weekend run plans the week ahead, never a past sprint.
    static func current(_ iterations: [Iteration], at t: Date) -> Iteration? {
        iterations.first { $0.contains(t) } ?? iterations.first { $0.start > t }
    }

    /// WIQL only names candidates: its index lags writes both ways, so every field is read back live and refiltered.
    private func fetch(_ p: SprintProject) async throws -> [SprintTask] {
        let api = client(p)
        let q = """
            SELECT [System.Id] FROM WorkItems
            WHERE [System.AreaPath] UNDER '\(wiqlEscape(p.areaPath))'
              AND [System.IterationPath] UNDER '\(wiqlEscape(p.iterationBase))'
              AND [System.AssignedTo] = '\(wiqlEscape(config.adoEmail))'
              AND [System.State] <> 'Removed'
            """
        let ids = try await api.wiql(q)
        guard !ids.isEmpty else { return [] }
        return try await api.batch(ids, fields: Self.fields).compactMap { o -> SprintTask? in
            guard let id = o["id"] as? Int, let f = o["fields"] as? JSONObject,
                  (f[Field.area] as? String ?? "").hasPrefix(p.areaPath),
                  f[Field.state] as? String != "Removed" else { return nil }
            return SprintTask(
                id: id, project: p.name,
                title: f[Field.title] as? String ?? "",
                type: f[Field.workItemType] as? String ?? "",
                state: f[Field.state] as? String ?? "",
                estimate: number(f[Field.originalEstimate]),
                completed: number(f[Field.completedWork]),
                priority: Int(number(f[Field.priority])),
                due: String((f[Field.dueDate] as? String ?? "").prefix(10)),
                parentID: f[Field.parent] as? Int ?? 0,
                iteration: f[Field.iteration] as? String ?? "")
        }
    }

    // MARK: Plans — pure rules over a loaded board, no network

    /// Active work left behind in a sprint that has already finished.
    func carryOverPlan(_ b: SprintBoard) -> [SprintChange] {
        let stale = Set(b.iterations.filter { $0.finish < b.sprint.start }.map(\.path))
        return movePlan(b.outside.filter { stale.contains($0.iteration) }.map(\.id), to: b.sprint.path, b)
    }

    /// Moving a container leaves its Tasks behind unless they go too — ADO moves neither for you.
    func movePlan(_ ids: [Int], to path: String, _ b: SprintBoard) -> [SprintChange] {
        var wanted: [SprintTask] = []
        for id in ids {
            guard let t = b.task(id) else { continue }
            wanted.append(t)
            if !t.carriesHours { wanted += b.children(id) }
        }
        var seen = Set<Int>()
        return wanted.filter { seen.insert($0.id).inserted && $0.iteration != path }.map {
            SprintChange(kind: .update($0.id), project: $0.project, title: "#\($0.id) \($0.title)",
                         detail: "\(Iteration(path: $0.iteration).name) → \(Iteration(path: path).name)",
                         ops: [PatchOp(op: "add", path: "/fields/\(Field.iteration)", value: path)])
        }
    }

    /// The ceremony tasks this sprint should have. Parity keeps planning and retro in different weeks.
    func activityPlan(_ b: SprintBoard) -> [SprintChange] {
        var out: [SprintChange] = []
        for p in config.projects {
            guard let group = config.activityGroup(p.name) else { continue }
            let have = Set(b.project(p.name).map(\.title))
            for item in group.items where item.parity.matches(b.sprint.number) {
                let title = item.render(b.sprint)
                guard !have.contains(title) else { continue }
                let due = dayString(b.sprint.start.addingTimeInterval(TimeInterval(priorityOffset(item.priority)) * 86400))
                var ops = [
                    PatchOp(op: "add", path: "/fields/\(Field.title)", value: title),
                    PatchOp(op: "add", path: "/fields/\(Field.assignedTo)", value: config.adoEmail),
                    PatchOp(op: "add", path: "/fields/\(Field.area)", value: p.areaPath),
                    PatchOp(op: "add", path: "/fields/\(Field.iteration)", value: b.sprint.path),
                    PatchOp(op: "add", path: "/fields/\(Field.originalEstimate)", value: 1),
                    PatchOp(op: "add", path: "/fields/\(Field.priority)", value: item.priority),
                    PatchOp(op: "add", path: "/fields/\(Field.dueDate)", value: due),
                ]
                if group.parentID > 0 { ops.append(client(p).parentRelation(group.parentID)) }
                out.append(SprintChange(kind: .create(parent: group.parentID), project: p.name, title: title,
                                        detail: "create · 1h · P\(item.priority) · due \(due)", ops: ops))
            }
        }
        return out
    }

    /// Fills the week: pinned ceremonies and In Progress first, then the rest by day capacity. A task already due
    /// inside this week keeps its day — a draft that reshuffles an arranged week is worse than one that adds to it.
    func schedulePlan(_ b: SprintBoard) -> [SprintChange] {
        let week = Set(b.sprint.days.map(dayString))
        let dayCap = config.workweekHours / 5
        var load = [Double](repeating: 0, count: 5)  // across every project, the ceiling the user actually feels
        var projectLoad: [String: [Double]] = [:]
        var pending: [SprintTask] = []

        func place(_ t: SprintTask, _ offset: Int) {
            load[offset] += t.estimate
            projectLoad[t.project, default: [Double](repeating: 0, count: 5)][offset] += t.estimate
        }

        for t in b.tasks where t.carriesHours && !t.done {
            if t.priority > 0, week.contains(t.due), let offset = b.sprint.days.firstIndex(where: { dayString($0) == t.due }) {
                place(t, offset)
            } else {
                pending.append(t)
            }
        }

        var out: [SprintChange] = []
        for t in pending.sorted(by: { ($0.state == "In Progress" ? 0 : 1, $0.title) < ($1.state == "In Progress" ? 0 : 1, $1.title) }) {
            let offset = Self.slot(t, load: load, projectCap: config.projects.first { $0.name == t.project }?.budget(config.workweekHours) ?? 0,
                                   projectLoad: projectLoad[t.project] ?? [Double](repeating: 0, count: 5), dayCap: dayCap)
            place(t, offset)
            let due = dayString(b.sprint.days[offset])
            let priority = offsetPriority(offset)
            guard t.priority != priority || t.due != due else { continue }
            out.append(SprintChange(
                kind: .update(t.id), project: t.project, title: "#\(t.id) \(t.title)",
                detail: "P\(t.priority == 0 ? "–" : "\(t.priority)") → P\(priority) · \(weekdayNames[offset]) · due \(due)",
                ops: [PatchOp(op: "add", path: "/fields/\(Field.priority)", value: priority),
                      PatchOp(op: "add", path: "/fields/\(Field.dueDate)", value: due)]))
        }
        return out
    }

    /// Monday for a planning ceremony and for work already underway; otherwise the earliest day with room, and when
    /// no day has room, the emptiest one — an overflowing week is the user's call, not a reason to drop the task.
    private static func slot(_ t: SprintTask, load: [Double], projectCap: Double, projectLoad: [Double], dayCap: Double) -> Int {
        if t.title.range(of: "sprint planning", options: .caseInsensitive) != nil { return 0 }
        if t.state == "In Progress" { return 0 }
        let perDay = projectCap / 5
        // The user accepts 1h of daily overflow; only past that is a day really full.
        if let i = (0..<5).first(where: { load[$0] + t.estimate <= dayCap + 1 && projectLoad[$0] + t.estimate <= perDay + 1 }) { return i }
        return load.indices.min { load[$0] < load[$1] } ?? 0
    }

    func fieldsChange(_ t: SprintTask, estimate: Double, offset: Int, _ b: SprintBoard) -> SprintChange? {
        let due = dayString(b.sprint.days[min(max(offset, 0), 4)])
        let priority = offsetPriority(offset)
        guard t.estimate != estimate || t.due != due || t.priority != priority else { return nil }
        return SprintChange(
            kind: .update(t.id), project: t.project, title: "#\(t.id) \(t.title)",
            detail: "\(hoursText(t.estimate)) → \(hoursText(estimate)) · P\(priority) · \(weekdayNames[min(max(offset, 0), 4)]) · due \(due)",
            ops: [PatchOp(op: "add", path: "/fields/\(Field.originalEstimate)", value: estimate),
                  PatchOp(op: "add", path: "/fields/\(Field.remainingWork)", value: estimate),
                  PatchOp(op: "add", path: "/fields/\(Field.priority)", value: priority),
                  PatchOp(op: "add", path: "/fields/\(Field.dueDate)", value: due)])
    }

    /// An ad-hoc Task under a container, with every planning field set from the start.
    func newTaskChange(project: SprintProject, parent: Int, title: String, estimate: Double, offset: Int, _ b: SprintBoard) -> SprintChange {
        let offset = min(max(offset, 0), 4)
        let due = dayString(b.sprint.days[offset])
        var ops = [
            PatchOp(op: "add", path: "/fields/\(Field.title)", value: title),
            PatchOp(op: "add", path: "/fields/\(Field.assignedTo)", value: config.adoEmail),
            PatchOp(op: "add", path: "/fields/\(Field.area)", value: project.areaPath),
            PatchOp(op: "add", path: "/fields/\(Field.iteration)", value: b.sprint.path),
            PatchOp(op: "add", path: "/fields/\(Field.originalEstimate)", value: estimate),
            PatchOp(op: "add", path: "/fields/\(Field.remainingWork)", value: estimate),
            PatchOp(op: "add", path: "/fields/\(Field.priority)", value: offsetPriority(offset)),
            PatchOp(op: "add", path: "/fields/\(Field.dueDate)", value: due),
        ]
        if parent > 0 { ops.append(client(project).parentRelation(parent)) }
        return SprintChange(kind: .create(parent: parent), project: project.name, title: title,
                            detail: "create · \(hoursText(estimate)) · \(weekdayNames[offset]) · due \(due)", ops: ops)
    }

    /// Hours belong on Tasks only: the user's ADO query sums Tasks, so an estimate on a container silently vanishes.
    func clearContainerHours(_ b: SprintBoard) -> [SprintChange] {
        (b.tasks + b.outside).filter { !$0.carriesHours && $0.estimate > 0 }.map {
            SprintChange(kind: .update($0.id), project: $0.project, title: "#\($0.id) \($0.title)",
                         detail: "clear \(hoursText($0.estimate)) on a \($0.type) — only Tasks carry hours",
                         ops: [PatchOp(op: "add", path: "/fields/\(Field.originalEstimate)", value: NSNull()),
                               PatchOp(op: "add", path: "/fields/\(Field.remainingWork)", value: NSNull())])
        }
    }

    // MARK: Writing

    /// Applies confirmed changes and reports what failed; one bad item never stops the rest.
    func apply(_ changes: [SprintChange]) async -> [String] {
        var errors: [String] = []
        for c in changes {
            let api = client(config.projects.first { $0.name == c.project } ?? config.projects[0])
            do {
                switch c.kind {
                case .update(let id): try await api.update(id, ops: c.ops)
                case .create: _ = try await api.create(type: typeTask, ops: c.ops)
                }
                AppLog.info("sprint write", ["item": c.workItem ?? 0, "detail": c.detail])
            } catch {
                errors.append("\(c.title): \(describe(error))")
                AppLog.error("sprint write failed", ["item": c.workItem ?? 0, "err": describe(error)])
            }
        }
        return errors
    }
}

// MARK: - Reading the board back

/// How each baseline task turned out, plus whatever showed up unplanned. Measured from the day snapshots, so it
/// keeps working for a sprint that has already closed: the baseline is the first day, and a task is late when the
/// first snapshot showing it Done falls after the day it was planned for.
func review(_ days: [SprintDay]) -> [(task: SprintTask, verdict: TaskVerdict)] {
    guard let first = days.first, let last = days.last else { return [] }
    let base = Dictionary(first.tasks.filter(\.carriesHours).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var doneOn: [Int: Date] = [:]
    for d in days {
        for t in d.tasks where t.done && doneOn[t.id] == nil { doneOn[t.id] = d.day }
    }
    var out: [(SprintTask, TaskVerdict)] = []
    for t in last.tasks.filter(\.carriesHours) {
        guard let b = base[t.id] else {
            out.append((t, .unplanned))
            continue
        }
        if t.done {
            let due = b.dueDay ?? .distantFuture
            out.append((t, (doneOn[t.id] ?? d0) > due ? .late : .onTime))
        } else {
            out.append((t, t.estimate != b.estimate ? .reestimated : .open))
        }
    }
    let present = Set(last.tasks.map(\.id))
    out += base.values.filter { !present.contains($0.id) }.map { ($0, .movedOut) }
    return out.sorted { $0.0.id < $1.0.id }
}

private let d0 = Date.distantPast

private func number(_ v: Any?) -> Double {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    return 0
}

/// "1.5h", "2h".
func hoursText(_ h: Double) -> String {
    h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h)
}
