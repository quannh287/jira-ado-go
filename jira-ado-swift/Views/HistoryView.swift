import SwiftUI

/// Who changed an ADO work item: this app's writes against everything edited by hand.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            search
            if !model.history.error.isEmpty {
                Label(model.history.error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if model.history.workItem != 0 { counts }
            Table(model.history.rows) {
                TableColumn("Rev") { Text("\($0.rev)").monospacedDigit() }.width(44)
                TableColumn("Source") { Pill($0.source.rawValue, $0.source.color) }.width(72)
                TableColumn("When") { Text($0.at.short) }.width(132)
                TableColumn("By") { Text($0.by) }.width(min: 110, ideal: 140)
                TableColumn("Changed") { Text($0.changes.joined(separator: " · ")).lineLimit(2) }
            }
            Text("ADO stamps a PAT write with the same identity as a web edit, so the source comes from this app's "
                + "own call log. A write answered with its revision is Sync; a revision inside a run's window that "
                + "no answer names — a comment, or a run whose log was deleted — is Sync?.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .navigationTitle("Item History")
        .navigationSubtitle(model.history.workItem == 0 ? "" : "#\(model.history.workItem) · \(plural(model.history.rows.count, "revision"))")
    }

    private var search: some View {
        @Bindable var model = model
        return HStack {
            TextField("ADO work item ID or URL", text: $model.history.input)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("history.item")
                .frame(maxWidth: 360)
                .onSubmit { Task { await model.loadHistory() } }
            Button("Look Up") { Task { await model.loadHistory() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.history.loading || model.history.input.isEmpty)
            if model.history.loading { ProgressView().controlSize(.small) }
            Spacer()
        }
    }

    private var counts: some View {
        HStack(spacing: 12) {
            ForEach(Revision.Source.allCases, id: \.self) { s in
                StatCard(label: s.label, value: "\(model.history.rows.count { $0.source == s })", color: s.color)
            }
        }
    }
}

extension Revision.Source {
    var color: Color {
        switch self {
        case .sync: .accentColor
        case .likelySync: .orange
        case .manual: .secondary
        }
    }

    var label: String {
        switch self {
        case .sync: "Written by sync"
        case .likelySync: "Probably sync"
        case .manual: "Edited by hand"
        }
    }
}

#Preview("Empty") {
    HistoryView().environment(PreviewData.model()).frame(width: 900, height: 560)
}
