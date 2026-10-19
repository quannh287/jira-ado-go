import SwiftUI

struct JobView: View {
    @Environment(AppModel.self) private var model
    let id: Int
    @State private var tab = Tab.configuration
    @State private var confirmDelete = false

    enum Tab: String, CaseIterable { case configuration = "Configuration", mappings = "Field Mappings", filters = "Filters",
                                       history = "Sync History", activity = "Activity Log", settings = "Settings" }

    var body: some View {
        if let j = model.store.job(id) {
            content(j)
        } else {
            ContentUnavailableView("Job not found", systemImage: "questionmark", description: Text("No job with ID \(id)."))
        }
    }

    private func content(_ j: Job) -> some View {
        let running = model.running.contains(id)
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Job sections", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("job.tabs")
            switch tab {
            case .configuration:
                editBar(0, "Name, ADO project and sync type.")
                Form {
                    KV("Name", j.name)
                    KV("Jira project", j.jiraKey)
                    KV("ADO project", j.adoProject)
                    KV("Direction", "Jira → ADO")
                    KV("Sync type", syncTypeLabel(j))
                    KV("Status", j.status.rawValue)
                    KV("Created", j.created.formatted(date: .abbreviated, time: .shortened))
                }
                .formStyle(.grouped)
            case .mappings:
                editBar(1, "Only mapped ADO fields are written; title, area, iteration and the Jira key always are.")
                Table(j.mappings.map { MappingRow(pair: $0) }) {
                    TableColumn("Jira field") { Text($0.pair.jira) }
                    TableColumn("ADO field") { Text($0.pair.ado) }
                }
            case .filters:
                editBar(2, "Comments, user filter, user mapping, area and iteration.")
                Form { FiltersRows(job: j) }.formStyle(.grouped)
            case .history:
                RunsTable(runs: (model.live[id].map { [$0.run] } ?? []) + model.store.runs(for: id))
            case .activity:
                List(Array(j.activity.reversed().enumerated()), id: \.offset) { _, a in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(a.at.short).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(a.text).textSelection(.enabled)
                    }
                }
            case .settings:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete job").bold()
                    Text("Deletes the job and its sync history. Work items already in ADO stay.").font(.callout).foregroundStyle(.secondary)
                    Button("Delete Job…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .help("Deletes the job and its sync history; work items already in ADO stay")
                }
                Spacer()
            }
        }
        .padding(20)
        .navigationTitle(j.name)
        .navigationSubtitle("\(j.jiraKey) → \(j.adoProject) · \(syncTypeLabel(j))")
        .toolbar { actions(j, running) }
        .confirmationDialog("Delete \(j.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.store.deleteJob(id)
                model.show("Deleted \(j.name)")
                model.open(.jobs)
            }
        } message: {
            Text("Its sync history is deleted too. This can't be undone.")
        }
    }

    @ToolbarContentBuilder
    private func actions(_ j: Job, _ running: Bool) -> some ToolbarContent {
        ToolbarItemGroup {
            if running {
                ProgressView().controlSize(.small)
                Text(progressText(model.live[id] ?? SyncProgress(run: Run()))).font(.caption).foregroundStyle(.secondary)
            } else {
                Pill(j.status.rawValue, j.status.color)
            }
            IconButton("Edit Job", systemImage: "pencil") { model.path.append(.edit(id, step: 0)) }
            if j.status == .active {
                IconButton("Pause", systemImage: "pause.circle") { model.store.setStatus(id, .paused) }.disabled(running)
            } else {
                IconButton("Resume", systemImage: "play.circle") { model.store.setStatus(id, .active) }
            }
            if running {
                IconButton("Cancel", systemImage: "stop.circle", role: .destructive,
                           help: "Stops after the current issue; the next sync resumes from the last checkpoint") { model.cancelRun(id) }
            } else {
                IconButton("Dry Run", systemImage: "eye",
                           help: "Dry Run: reads Jira and ADO, writes nothing; the report shows what a sync would send") { model.dryRun(id) }
                    .disabled(j.status != .active)
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { model.syncNow(id) }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .disabled(j.status != .active)
                    .help(j.status == .active ? "Syncs Jira issues changed since the last run to ADO" : "Only ACTIVE jobs can sync")
            }
        }
    }

    /// Sits above a read-only tab and opens the editor at its step.
    private func editBar(_ step: Int, _ hint: String) -> some View {
        HStack {
            Text(hint).font(.callout).foregroundStyle(.secondary)
            Spacer()
            IconButton("Edit…", systemImage: "pencil") { model.path.append(.edit(id, step: step)) }
        }
    }
}

private struct MappingRow: Identifiable {
    let pair: FieldPair
    var id: String { pair.ado }
}

/// The read-only Filters summary shared by the job's Filters tab and the editor's Review step.
struct FiltersRows: View {
    let job: Job

    var body: some View {
        let f = job.filters, (area, iteration) = job.paths(at: Date())
        KV("Sync comments", f.syncComments ? "Yes" : "No")
        KV("Assignees", !f.userFilter ? "Everyone" : f.assignees.trimmingCharacters(in: .whitespaces).isEmpty ? "Assignees mapped to an ADO email" : f.assignees)
        KV("Area path", area)
        if f.autoPaths {
            KV("In active Jira sprint", "\(iteration) (weekly, Sprint \(f.anchorSprint) = \(f.anchorDate))")
            KV("Otherwise (backlog)", job.backlogPath)
        } else {
            KV("Iteration", iteration)
        }
        if f.keepIteration == true {
            KV("Existing items", "Keep the ADO iteration" + (f.commentIteration == true ? ", comment the difference" : ""))
        }
        if f.users.isEmpty { KV("User mapping", "None") }
        ForEach(Array(f.users.enumerated()), id: \.offset) { _, u in KV(u.jira, u.adoEmail) }
    }
}

/// Runs, newest first; a click opens the run's report. With selection, rows multi-select and show a delete button instead.
/// A run still in flight has id 0 and shows as "Live".
struct RunsTable: View {
    @Environment(AppModel.self) private var model
    let runs: [Run]
    var selection: Binding<Set<Int>>?

    var body: some View {
        Group {
            if let selection {
                Table(runs, selection: selection) { columns(manage: true) }
                    .contextMenu(forSelectionType: Run.ID.self) { _ in } primaryAction: { ids in open(ids.first) }
            } else {
                // A click opens the run.
                Table(runs, selection: Binding<Run.ID?>(get: { nil }, set: { open($0) })) { columns(manage: false) }
            }
        }
        .overlay {
            if runs.isEmpty { ContentUnavailableView("No runs yet", systemImage: "clock", description: Text("Press Sync Now on an ACTIVE job.")) }
        }
    }

    private func open(_ id: Int?) {
        guard let id, let r = id == 0 ? runs.first(where: { $0.id == 0 }) : model.store.run(id) else { return }
        model.path.append(.report(r.jobID, runID: r.id == 0 ? nil : r.id))
    }

    @TableColumnBuilder<Run, Never>
    private func columns(manage: Bool) -> some TableColumnContent<Run, Never> {
        TableColumn("Run") { Text($0.id == 0 ? "Live" : "#\($0.id)") }.width(60)
        TableColumn("Job") { r in Text(model.store.job(r.jobID)?.name ?? "Job \(r.jobID)") }
        TableColumn("Started") { Text($0.started.short) }.width(140)
        TableColumn("Status") { r in Pill(r.id == 0 ? "running" : r.status.rawValue, r.id == 0 ? .secondary : r.status.color) }.width(80)
        TableColumn("Created") { r in count(r, .created) }.width(60)
        TableColumn("Updated") { r in count(r, .updated) }.width(60)
        TableColumn("Skipped") { r in count(r, .skipped) }.width(60)
        TableColumn("Failed") { r in count(r, .failed) }.width(55)
        TableColumn("Duration") { r in Text(r.id == 0 ? "—" : fmtDuration(r.duration)).foregroundStyle(.secondary) }.width(70)
        if manage {
            TableColumn("") { r in
                IconButton("Delete", systemImage: "trash", role: .destructive) { model.store.deleteRuns([r.id]) }
                    .buttonStyle(.borderless)
            }
            .width(60)
        }
    }

    private func count(_ r: Run, _ o: Outcome) -> some View {
        Text("\(r.count(o))").foregroundStyle(o.color).frame(maxWidth: .infinity, alignment: .trailing)
    }
}

#Preview("Job") {
    NavigationStack { JobView(id: 1) }.previewModel().frame(width: 1000, height: 640)
}

#Preview("Job · Syncing") {
    NavigationStack { JobView(id: 1) }.previewModel(PreviewData.model(live: true)).frame(width: 1000, height: 640)
}

#Preview("Job · Not Found") {
    NavigationStack { JobView(id: 99) }.previewModel().frame(width: 600, height: 400)
}

#Preview("Runs Table") {
    RunsTable(runs: PreviewData.model().store.runs).previewModel().frame(width: 960, height: 300)
}

#Preview("Runs Table · Manage") {
    @Previewable @State var selection: Set<Int> = [2]
    RunsTable(runs: PreviewData.model().store.runs, selection: $selection).previewModel().frame(width: 960, height: 300)
}

#Preview("Filters Rows") {
    Form { FiltersRows(job: PreviewData.job) }.formStyle(.grouped).frame(width: 600, height: 400)
}
