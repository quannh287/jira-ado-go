import AppKit
import UniformTypeIdentifiers
import SwiftUI

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var jobFilter: Int?  // nil = all jobs
    @State private var statusFilter: RunStatus?  // nil = all statuses
    @State private var selection = Set<Int>()
    @State private var confirm = false

    private var runs: [Run] {
        model.store.runs.filter { (jobFilter == nil || $0.jobID == jobFilter) && (statusFilter == nil || $0.status == statusFilter) }
    }

    var body: some View {
        let runs = runs, chosen = selection.intersection(model.store.runs.map(\.id))
        RunsTable(runs: runs, selection: $selection)
            .padding(20)
            .navigationTitle("Logs")
            .navigationSubtitle("\(runs.count) of \(model.store.runs.count) runs")
            .toolbar {
                ToolbarItemGroup {
                    Picker("Job", selection: $jobFilter) {
                        Text("All jobs").tag(Int?.none)
                        ForEach(model.store.jobs) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                    Picker("Status", selection: $statusFilter) {
                        Text("All statuses").tag(RunStatus?.none)
                        ForEach(RunStatus.allCases, id: \.self) { Text($0.rawValue).tag(RunStatus?.some($0)) }
                    }
                    Button("Export JSON") { export(runs) }.disabled(runs.isEmpty)
                    Button(chosen.isEmpty ? "Delete Selected" : "Delete \(chosen.count)…", role: .destructive) { confirm = true }
                        .disabled(chosen.isEmpty)
                }
            }
            .confirmationDialog("Delete \(chosen.count) runs?", isPresented: $confirm) {
                Button("Delete", role: .destructive) {
                    model.store.deleteRuns(chosen)
                    selection = []
                    model.show("Deleted \(chosen.count) runs")
                }
            } message: {
                Text("Their reports are deleted too. This can't be undone.")
            }
    }

    private func export(_ runs: [Run]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        let panel = NSSavePanel()
        panel.title = "Export runs"
        panel.nameFieldStringValue = "sync-runs.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try enc.encode(runs).write(to: url)
            model.show("Exported \(runs.count) runs")
        } catch { model.show("Export failed: " + describe(error)) }
    }
}

#Preview("Logs") {
    NavigationStack { LogsView() }.previewModel().frame(width: 1100, height: 500)
}

#Preview("Logs · Empty") {
    NavigationStack { LogsView() }.previewModel(PreviewData.model(empty: true)).frame(width: 1100, height: 500)
}
