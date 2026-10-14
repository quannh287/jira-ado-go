import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store, now = Date()
        let today = store.runs.filter { now.timeIntervalSince($0.started) < 86400 }
        let ok = today.filter { $0.status == .success }.count
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                StatCard(label: "Total Jobs", value: "\(store.jobs.count)")
                StatCard(label: "Active", value: "\(store.jobs.filter { $0.status == .active }.count)", color: .green)
                StatCard(label: "Runs (24h)", value: "\(today.count)")
                StatCard(label: "Success Rate (24h)", value: today.isEmpty ? "—" : "\(ok * 100 / today.count)%", color: .accentColor)
            }
            JobsTable()
        }
        .padding(20)
        .navigationTitle("Dashboard")
        .navigationSubtitle("Jira → ADO sync jobs at a glance")
    }
}

struct JobsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        JobsTable()
            .padding(20)
            .navigationTitle("Sync Jobs")
            .navigationSubtitle("\(model.store.jobs.count) jobs")
    }
}

struct JobsTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // A click opens the job.
        Table(model.store.jobs, selection: Binding<Job.ID?>(get: { nil }, set: { if let id = $0 { model.path.append(.job(id)) } })) {
            TableColumn("Name", value: \.name)
            TableColumn("Jira", value: \.jiraKey).width(80)
            TableColumn("ADO Project", value: \.adoProject).width(140)
            TableColumn("Type") { Text($0.type.rawValue) }.width(90)
            TableColumn("Status") { j in
                if model.running.contains(j.id) { Pill("SYNCING", .accentColor) } else { Pill(j.status.rawValue, j.status.color) }
            }
            .width(90)
            TableColumn("Last Run") { j in
                if let r = model.store.lastRun(j.id) {
                    HStack(spacing: 6) {
                        Pill(r.status.rawValue, r.status.color)
                        Text(ago(r.started, Date())).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Never").foregroundStyle(.secondary)
                }
            }
            .width(150)
        }
        .overlay {
            if model.store.jobs.isEmpty {
                ContentUnavailableView {
                    Label("No sync jobs yet", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("⌘N  New Sync Job\n⌘K  Search")
                } actions: {
                    Button("New Sync Job") { model.path.append(.create) }
                        .accessibilityIdentifier("empty.newJob")
                }
            }
        }
    }
}

#Preview("Dashboard") {
    NavigationStack { DashboardView() }.previewModel().frame(width: 960, height: 600)
}

#Preview("Dashboard · Empty") {
    NavigationStack { DashboardView() }.previewModel(PreviewData.model(empty: true)).frame(width: 960, height: 600)
}

#Preview("Sync Jobs") {
    NavigationStack { JobsView() }.previewModel().frame(width: 960, height: 500)
}

#Preview("Jobs Table · Syncing") {
    JobsTable().previewModel(PreviewData.model(live: true)).frame(width: 900, height: 300)
}
