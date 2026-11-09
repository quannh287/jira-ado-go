import SwiftUI

struct JobsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // A one-row table is worth less than the job itself, and one job is the normal case here.
        if model.store.jobs.count == 1 {
            JobView(id: model.store.jobs[0].id)
        } else {
            JobsTable()
                .padding(20)
                .navigationTitle("Sync Jobs")
                .navigationSubtitle("\(model.store.jobs.count) jobs")
        }
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
                    Button("New Sync Job", systemImage: "plus") { model.path.append(.create) }
                        .help("Creates a job that syncs one Jira project to one ADO project")
                        .accessibilityIdentifier("empty.newJob")
                }
            }
        }
    }
}

#Preview("Sync Jobs · Empty") {
    NavigationStack { JobsView() }.previewModel(PreviewData.model(empty: true)).frame(width: 960, height: 500)
}

#Preview("Sync Jobs") {
    NavigationStack { JobsView() }.previewModel().frame(width: 960, height: 500)
}

#Preview("Jobs Table · Syncing") {
    JobsTable().previewModel(PreviewData.model(live: true)).frame(width: 900, height: 300)
}
