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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !state.error.isEmpty { Label(state.error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if state.loaded {
                    capacity
                    burndown
                    tasks
                    outside
                } else if !state.loading {
                    ContentUnavailableView("No sprint loaded", systemImage: "chart.bar.xaxis",
                                           description: Text("Refresh to read the current sprint from ADO."))
                        .padding(.top, 40)
                }
            }
            .padding(20)
        }
        .navigationTitle(state.loaded ? "\(board.sprint.name) · \(hoursText(state.committed)) / \(hoursText(model.sprintConfig.budget))" : "Sprint")
        .toolbar { toolbar }
        .overlay { if state.loading { ProgressView().controlSize(.large) } }
        .task { if !state.loaded { await model.loadSprint() } }
        .sheet(isPresented: Binding(get: { !state.pending.isEmpty }, set: { if !$0 { model.cancelSprintChanges() } })) { confirmSheet }
        .sheet(item: $editing) { TaskFieldsSheet(task: $0) }
        .sheet(item: $adding) { NewTaskSheet(parent: $0) }
    }

    // MARK: Pieces

    private var capacity: some View {
        HStack(spacing: 12) {
            ForEach(model.sprintConfig.projects.filter { $0.effortPct > 0 }) { p in
                let committed = state.committed(p.name), budget = p.budget(model.sprintConfig.workweekHours)
                StatCard(label: p.name, value: "\(hoursText(committed)) / \(hoursText(budget))",
                         color: committed > budget + 1 ? .orange : .primary)
            }
            StatCard(label: state.unplanned > 0 ? "Planned + unplanned" : "Total",
                     value: state.unplanned > 0 ? "\(hoursText(state.planned)) + \(hoursText(state.unplanned))" : hoursText(state.committed))
        }
    }

    private var burndown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Burndown").font(.headline)
            Chart {
                ForEach(planLine, id: \.day) { p in
                    LineMark(x: .value("Day", p.day), y: .value("Hours", p.value), series: .value("Series", "Plan"))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                ForEach(state.days, id: \.day) { d in
                    BarMark(x: .value("Day", d.day), y: .value("Hours", burned(d)))
                        .foregroundStyle(Color.green.opacity(0.35))
                    LineMark(x: .value("Day", d.day), y: .value("Hours", d.remaining), series: .value("Series", "Actual"))
                        .foregroundStyle(Color.accentColor)
                        .symbol(.circle)
                }
            }
            .chartXAxis { AxisMarks(values: board.sprint.days) { v in
                AxisValueLabel { Text(weekdayNames[v.index % 5]) }
                AxisGridLine()
            } }
            .chartYAxisLabel("hours")
            .frame(height: 200)
            if state.days.count < 2 {
                Text("The actual line fills in from tomorrow — one snapshot is taken per day.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In \(board.sprint.name)").font(.headline)
            Table(rows, selection: Binding(get: { state.selection }, set: { model.sprint.selection = $0 })) {
                TableColumn("ID") { Text("#\($0.task.id)").monospacedDigit() }.width(60)
                TableColumn("Title") { r in
                    Text(r.child ? "↳ \(r.task.title)" : r.task.title).strikethrough(r.task.done)
                }
                TableColumn("State") { Text($0.task.state).foregroundStyle(.secondary) }.width(90)
                TableColumn("Est") { Text($0.task.carriesHours ? hoursText($0.task.estimate) : "—").monospacedDigit() }.width(50)
                TableColumn("Day") { r in
                    Text(r.task.priority > 0 ? "P\(r.task.priority) · \(r.task.due)" : "—").foregroundStyle(.secondary).monospacedDigit()
                }.width(130)
                TableColumn("Note") { r in
                    if let v = r.verdict { Pill(v.rawValue, color(v)) }
                }.width(110)
            }
            .frame(height: 320)
            .contextMenu(forSelectionType: SprintTask.ID.self) { ids in
                Button("Push to next sprint") { pushOut(ids) }
                    .disabled(board.next == nil)
                if let t = one(ids) {
                    Button("Edit estimate and day…") { editing = t }
                    if !t.carriesHours { Button("Add task under this…") { adding = t } }
                }
            }
        }
    }

    @ViewBuilder private var outside: some View {
        if !board.outside.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Outside the sprint").font(.headline)
                Table(board.outside, selection: Binding(get: { state.outsideSelection }, set: { model.sprint.outsideSelection = $0 })) {
                    TableColumn("ID") { Text("#\($0.id)").monospacedDigit() }.width(60)
                    TableColumn("Title") { Text($0.title) }
                    TableColumn("Type") { Text($0.type).foregroundStyle(.secondary) }.width(140)
                    TableColumn("Where") { Text(Iteration(path: $0.iteration).name).foregroundStyle(.secondary) }.width(120)
                    TableColumn("Est") { Text($0.carriesHours ? hoursText($0.estimate) : "—").monospacedDigit() }.width(50)
                }
                .frame(height: 200)
                .contextMenu(forSelectionType: SprintTask.ID.self) { ids in
                    Button("Pull into \(board.sprint.name)") { pullIn(ids) }
                }
                Button("Pull selected into \(board.sprint.name)") { pullIn(state.outsideSelection) }
                    .disabled(state.outsideSelection.isEmpty)
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

    private var planLine: [(day: Date, value: Double)] {
        let total = state.days.first.map { committedHours($0.tasks) } ?? state.committed
        let days = board.sprint.days
        return days.indices.map { (days[$0], total * Double(days.count - 1 - $0) / Double(max(days.count - 1, 1))) }
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
