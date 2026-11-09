import Charts
import SwiftUI

/// The week: capacity against budget, the burndown read back from the day snapshots, and the tasks themselves —
/// pulled in, pushed out or re-dated as the week turns out differently from Monday.
struct SprintView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SprintTask?
    @State private var adding: SprintTask?

    private var state: SprintState { model.sprint }
    private var board: SprintBoard { state.board }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !state.error.isEmpty { Label(state.error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if state.loaded {
                header
                week
                tasks
                outside
            } else if !state.loading {
                ContentUnavailableView("No sprint loaded", systemImage: "calendar",
                                       description: Text("Refresh to read the current sprint from ADO."))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(state.loaded ? "\(board.sprint.name) · \(dateRange)" : "Sprint")
        .toolbar { toolbar }
        .overlay { if state.loading { ProgressView().controlSize(.large) } }
        .task { if !state.loaded { await model.loadSprint() } }
        .sheet(isPresented: Binding(get: { !state.pending.isEmpty }, set: { if !$0 { model.cancelSprintChanges() } })) { confirmSheet }
        .sheet(item: $editing) { TaskFieldsSheet(task: $0) }
        .sheet(item: $adding) { NewTaskSheet(parent: $0) }
    }

    // MARK: Pieces

    /// Capacity, what needs attention and the burndown in one band, framed like the day columns so it sits in the
    /// page instead of floating above it.
    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            capacity
            Divider()
            flags
            burndown.frame(width: 292)
        }
        .padding(12)
        .frame(height: 148)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(.separatorColor)))
    }

    /// The week's loose ends, counted. Each line is work the planning skill would otherwise have to find again.
    private var flags: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Needs attention").font(.caption).foregroundStyle(.secondary)
            if issues.isEmpty {
                Label("Nothing outstanding", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            } else {
                ForEach(issues.prefix(4), id: \.self) { i in
                    Label(i, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if issues.count > 4 { Text("+\(issues.count - 4) more").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One compact gauge a project, read side by side: the number says how much, the bar says how close to full.
    private var capacity: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(model.sprintConfig.projects.filter { $0.effortPct > 0 }) { p in
                CapacityBar(label: p.name, committed: state.committed(p.name),
                            budget: p.budget(model.sprintConfig.workweekHours), tint: tint(p.name))
            }
            CapacityBar(label: "Total", committed: state.committed, budget: model.sprintConfig.budget,
                        tint: .secondary, note: state.unplanned > 0 ? "+\(hoursText(state.unplanned)) unplanned" : "")
        }
    }

    private var burndown: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Burndown").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(planLine, id: \.name) { p in
                    LineMark(x: .value("Day", p.name), y: .value("Hours", p.value), series: .value("Series", "Plan"))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(actualLine, id: \.name) { a in
                    BarMark(x: .value("Day", a.name), y: .value("Hours", a.burned), width: .fixed(10))
                        .foregroundStyle(Color.green.opacity(0.3))
                    LineMark(x: .value("Day", a.name), y: .value("Hours", a.remaining), series: .value("Series", "Actual"))
                        .foregroundStyle(Color.accentColor)
                        .symbol(.circle)
                }
            }
            .chartXScale(domain: weekdayNames)
            .chartXAxis { AxisMarks { AxisValueLabel().font(.caption2); AxisGridLine() } }
            .chartYAxis { AxisMarks(position: .trailing) { AxisValueLabel().font(.caption2); AxisGridLine() } }
            .frame(height: 76)
            Text(state.days.count < 2 ? "Actual fills in from tomorrow — one snapshot a day."
                                      : "Plan from Monday · bars are hours closed that day")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The week itself, which is what planning actually looks at: five days, what sits on each, how full it is.
    private var week: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(board.sprint.days.enumerated()), id: \.offset) { i, day in
                DayColumn(name: weekdayNames[i], day: day, tasks: scheduled[dayString(day)] ?? [],
                          cap: model.sprintConfig.workweekHours / 5, selection: selectionBinding, tint: tint)
            }
            if !unscheduled.isEmpty {
                DayColumn(name: "Unscheduled", day: nil, tasks: unscheduled, cap: 0, selection: selectionBinding, tint: tint)
                    .frame(width: 150)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var tasks: some View {
        Table(rows, selection: selectionBinding) {
            TableColumn("ID") { Text(verbatim: "\($0.task.id)").monospacedDigit().textSelection(.enabled) }.width(62)
            TableColumn("Title") { r in
                Text(r.child ? "↳ \(r.task.title)" : r.task.title).strikethrough(r.task.done)
            }
            TableColumn("State") { Text($0.task.state).foregroundStyle(.secondary) }.width(90)
            TableColumn("Est") { Text($0.task.carriesHours ? hoursText($0.task.estimate) : "—").monospacedDigit() }.width(50)
            TableColumn("Day") { r in
                Text(verbatim: day(r.task)).foregroundStyle(.secondary).monospacedDigit()
            }.width(130)
            TableColumn("Note") { r in
                // "not done" on every open task says nothing on a Monday; only the exceptions earn a pill.
                if let v = r.verdict, v != .open { Pill(v.rawValue, color(v)) }
            }.width(110)
        }
        .frame(minHeight: 180, maxHeight: .infinity)
        .contextMenu(forSelectionType: SprintTask.ID.self) { ids in
            Button("Push to next sprint") { pushOut(ids) }
                .disabled(board.next == nil)
            if let t = one(ids) {
                Button("Edit estimate and day…") { editing = t }
                if !t.carriesHours { Button("Add task under this…") { adding = t } }
            }
        }
    }

    @ViewBuilder private var outside: some View {
        if !board.outside.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Outside the sprint").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Pull selected into \(board.sprint.name)") { pullIn(state.outsideSelection) }
                        .disabled(state.outsideSelection.isEmpty)
                        .controlSize(.small)
                }
                Table(board.outside, selection: Binding(get: { state.outsideSelection }, set: { model.sprint.outsideSelection = $0 })) {
                    TableColumn("ID") { Text(verbatim: "\($0.id)").monospacedDigit().textSelection(.enabled) }.width(60)
                    TableColumn("Title") { Text($0.title) }
                    TableColumn("Type") { Text($0.type).foregroundStyle(.secondary) }.width(140)
                    TableColumn("Where") { Text(Iteration(path: $0.iteration).name).foregroundStyle(.secondary) }.width(120)
                    TableColumn("Est") { Text($0.carriesHours ? hoursText($0.estimate) : "—").monospacedDigit() }.width(50)
                }
                .frame(height: 150)
                .contextMenu(forSelectionType: SprintTask.ID.self) { ids in
                    Button("Pull into \(board.sprint.name)") { pullIn(ids) }
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            IconButton("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadSprint() } }
                .disabled(state.loading)
            Menu {
                Button("Move carry-over in…") { propose("Move carry-over", SprintTracker.carryOverPlan) }
                Button("Create activity tasks…") { propose("Activity tasks", SprintTracker.activityPlan) }
                Button("Set priorities and due dates…") { propose("Weekly schedule", SprintTracker.schedulePlan) }
                Button("Clear hours on containers…") { propose("Container hours", SprintTracker.clearContainerHours) }
            } label: {
                Label("Plan", systemImage: "wand.and.stars")
            }
            .disabled(!state.loaded)
        }
    }

    private var confirmSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.pendingTitle).font(.title3.bold())
            Text("\(state.pending.count) change\(state.pending.count == 1 ? "" : "s") will be written to ADO.")
                .foregroundStyle(.secondary)
            List(state.pending) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).lineLimit(1)
                    Text("\(c.project) · \(c.detail)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 280)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelSprintChanges() }.keyboardShortcut(.cancelAction)
                Button("Write to ADO") { Task { await model.applySprintChanges() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.applying)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: Data

    private struct Row: Identifiable {
        var task: SprintTask
        var child: Bool
        var verdict: TaskVerdict?
        var id: Int { task.id }
    }

    /// Containers first, each followed by its tasks; orphans last.
    private var rows: [Row] {
        let verdicts = Dictionary(review(state.days).map { ($0.task.id, $0.verdict) }, uniquingKeysWith: { a, _ in a })
        let containers = board.tasks.filter { !$0.carriesHours }.sorted { $0.id < $1.id }
        var out = containers.flatMap { c in
            [Row(task: c, child: false, verdict: nil)]
                + board.tasks.filter { $0.parentID == c.id }.sorted { $0.id < $1.id }
                    .map { Row(task: $0, child: true, verdict: verdicts[$0.id]) }
        }
        let placed = Set(out.map(\.id))
        out += board.tasks.filter { !placed.contains($0.id) }.sorted { $0.id < $1.id }
            .map { Row(task: $0, child: false, verdict: verdicts[$0.id]) }
        return out
    }

    private var selectionBinding: Binding<Set<Int>> {
        Binding(get: { state.selection }, set: { model.sprint.selection = $0 })
    }

    /// "9–13 Nov".
    private var dateRange: String {
        let days = board.sprint.days
        guard let first = days.first, let last = days.last else { return "" }
        return "\(first.formatted(.dateTime.day()))–\(last.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// Tasks that carry hours, by the day they are due; anything without a day in this week stands apart.
    private var scheduled: [String: [SprintTask]] {
        Dictionary(grouping: board.tasks.filter { $0.carriesHours && weekDays.contains($0.due) }, by: \.due)
    }

    private var unscheduled: [SprintTask] {
        board.tasks.filter { $0.carriesHours && !weekDays.contains($0.due) }
    }

    private var weekDays: Set<String> { Set(board.sprint.days.map(dayString)) }

    /// One stable colour per project, so a chip in the week grid says whose it is without a label.
    private func tint(_ project: String) -> Color {
        let i = model.sprintConfig.projects.firstIndex { $0.name == project } ?? 0
        return [Color.accentColor, .teal, .orange, .pink][i % 4]
    }

    private var issues: [String] {
        var out: [String] = []
        func line(_ n: Int, _ one: String, _ many: String) { if n > 0 { out.append("\(n) \(n == 1 ? one : many)") } }
        line(board.tasks.filter { $0.carriesHours && !$0.done && $0.estimate == 0 }.count, "task with no estimate", "tasks with no estimate")
        line(unscheduled.filter { !$0.done }.count, "task not on a day", "tasks not on a day")
        line(board.tasks.filter { !$0.carriesHours && !$0.done && board.children($0.id).isEmpty }.count, "item with no task", "items with no task")
        line(board.tasks.filter { !$0.carriesHours && $0.estimate > 0 }.count, "container carrying hours", "containers carrying hours")
        let cap = model.sprintConfig.workweekHours / 5
        line(board.sprint.days.filter { (scheduled[dayString($0)] ?? []).reduce(0) { $0 + $1.estimate } > cap + 1 }.count, "day over capacity", "days over capacity")
        let stale = Set(board.iterations.filter { $0.finish < board.sprint.start }.map(\.path))
        line(board.outside.filter { stale.contains($0.iteration) }.count, "item left in a finished sprint", "items left in a finished sprint")
        return out
    }

    private var planLine: [(name: String, value: Double)] {
        let total = state.days.first.map { committedHours($0.tasks) } ?? state.committed
        return weekdayNames.indices.map { (weekdayNames[$0], total * Double(4 - $0) / 4) }
    }

    /// Snapshots placed on the weekday they were taken; a snapshot outside the sprint week has nowhere to go.
    private var actualLine: [(name: String, remaining: Double, burned: Double)] {
        state.days.compactMap { d in
            guard let i = board.sprint.days.firstIndex(where: { dayString($0) == dayString(d.day) }) else { return nil }
            return (weekdayNames[i], d.remaining, burned(d))
        }
    }

    /// Hours closed on that day alone; the snapshot stores the running total.
    private func burned(_ d: SprintDay) -> Double {
        guard let i = state.days.firstIndex(where: { $0.day == d.day }), i > 0 else { return d.doneHours }
        return max(d.doneHours - state.days[i - 1].doneHours, 0)
    }

    private func color(_ v: TaskVerdict) -> Color {
        switch v {
        case .onTime: .green
        case .late: .orange
        case .open: .secondary
        case .movedOut: .secondary
        case .unplanned: .purple
        case .reestimated: .accentColor
        }
    }

    private func day(_ t: SprintTask) -> String {
        guard t.priority > 0 else { return "—" }
        return t.due.isEmpty ? "P\(t.priority)" : "P\(t.priority) · \(t.due)"
    }

    private func one(_ ids: Set<Int>) -> SprintTask? {
        ids.count == 1 ? board.task(ids.first ?? 0) : nil
    }

    // MARK: Actions

    private func propose(_ title: String, _ plan: @escaping (SprintTracker) -> (SprintBoard) -> [SprintChange]) {
        guard let t = model.tracker() else { return }
        model.proposeSprint(title, plan(t)(board))
    }

    private func pullIn(_ ids: Set<Int>) {
        guard let t = model.tracker() else { return }
        model.proposeSprint("Pull into \(board.sprint.name)", t.movePlan(Array(ids), to: board.sprint.path, board))
    }

    private func pushOut(_ ids: Set<Int>) {
        guard let t = model.tracker(), let next = board.next else { return }
        model.proposeSprint("Push to \(next.name)", t.movePlan(Array(ids), to: next.path, board))
    }
}

/// How much of a budget is committed, with the budget itself as the tick: over it reads as over at a glance.
private struct CapacityBar: View {
    let label: String
    let committed: Double
    let budget: Double
    var tint: Color = .accentColor
    var note = ""

    private var over: Bool { committed > budget + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: hoursText(committed)).font(.title3.bold()).monospacedDigit()
                    .foregroundStyle(over ? .orange : .primary)
                Text(verbatim: "/ \(hoursText(budget))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let full = max(budget, committed, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(over ? Color.orange : tint)
                        .frame(width: geo.size.width * committed / full)
                    // The budget tick only means something while something sits past it.
                    if over {
                        Rectangle().fill(.primary).frame(width: 1)
                            .offset(x: geo.size.width * budget / full)
                    }
                }
            }
            .frame(height: 6)
            if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(width: 104)
    }
}

/// One weekday of the grid: what is due on it and how full that leaves it.
private struct DayColumn: View {
    let name: String
    let day: Date?
    let tasks: [SprintTask]
    let cap: Double
    @Binding var selection: Set<Int>
    let tint: (String) -> Color

    private var load: Double { tasks.reduce(0) { $0 + $1.estimate } }
    /// The user accepts an hour of daily overflow; past that the day is really over.
    private var over: Bool { cap > 0 && load > cap + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(name).font(.caption.bold())
                Spacer()
                Text(verbatim: cap > 0 ? "\(hoursText(load))/\(hoursText(cap))" : hoursText(load))
                    .font(.caption2).monospacedDigit().foregroundStyle(over ? .orange : .secondary)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tasks) { t in chip(t) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(over ? Color.orange.opacity(0.6) : Color(.separatorColor)))
    }

    private func chip(_ t: SprintTask) -> some View {
        let picked = selection.contains(t.id)
        return HStack(spacing: 6) {
            Capsule().fill(tint(t.project)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.caption2).lineLimit(2).strikethrough(t.done)
                Text(verbatim: "\(t.id) · \(hoursText(t.estimate))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(t.done ? 0.5 : 1)
        .background(picked ? Color.accentColor.opacity(0.18) : Color(.textBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selection = picked ? [] : [t.id] }
    }
}

/// Estimate plus the weekday it is due; the day decides the ADO priority.
private struct TaskFieldsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: SprintTask
    @State private var estimate = 0.0
    @State private var offset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.title).font(.headline).lineLimit(2)
            Form {
                TextField("Estimate (hours)", value: $estimate, format: .number)
                Picker("Day", selection: $offset) {
                    ForEach(weekdayNames.indices, id: \.self) { Text("\(weekdayNames[$0]) · P\(offsetPriority($0))").tag($0) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review change") {
                    if let t = model.tracker(), let c = t.fieldsChange(task, estimate: estimate, offset: offset, model.sprint.board) {
                        model.proposeSprint("Edit #\(task.id)", [c])
                    } else {
                        model.show("Nothing changed.")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            estimate = task.estimate
            offset = task.dueDay.flatMap { d in model.sprint.board.sprint.days.firstIndex { dayString($0) == dayString(d) } } ?? priorityOffset(task.priority)
        }
    }
}

/// An ad-hoc task under a PBI, Bug or User Story mid-week.
private struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let parent: SprintTask
    @State private var title = ""
    @State private var estimate = 1.0
    @State private var offset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New task under #\(parent.id)").font(.headline)
            Text(parent.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Form {
                TextField("Title", text: $title)
                TextField("Estimate (hours)", value: $estimate, format: .number)
                Picker("Day", selection: $offset) {
                    ForEach(weekdayNames.indices, id: \.self) { Text("\(weekdayNames[$0]) · P\(offsetPriority($0))").tag($0) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review change") {
                    if let t = model.tracker(), let p = model.sprintConfig.projects.first(where: { $0.name == parent.project }) {
                        model.proposeSprint("New task", [t.newTaskChange(project: p, parent: parent.id, title: title,
                                                                        estimate: estimate, offset: offset, model.sprint.board)])
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

#Preview("Sprint") {
    SprintView().environment(PreviewData.model()).frame(width: 980, height: 700)
}
