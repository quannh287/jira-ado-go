import SwiftUI

/// A coloured capsule label: statuses, outcomes, kinds.
struct Pill: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct StatCard: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.bold()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// A read-only row of a Form.
struct KV: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent(label) { Text(value).textSelection(.enabled) }
    }
}

/// Monospaced, selectable text in a box, for request and response bodies.
struct Mono: View {
    let text: String
    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 160)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }
}

extension JobStatus {
    var color: Color { self == .active ? .green : .orange }
}

extension RunStatus {
    var color: Color {
        switch self {
        case .success: .green
        case .partial: .orange
        case .failed: .red
        }
    }
}

extension Outcome {
    var color: Color {
        switch self {
        case .created: .green
        case .updated: .accentColor
        case .skipped: .secondary
        case .failed: .red
        }
    }
}

extension Date {
    /// "Oct 14 09:00:05".
    var short: String { formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute().second()) }
}

#Preview("Pills") {
    HStack {
        ForEach(RunStatus.allCases, id: \.self) { Pill($0.rawValue, $0.color) }
        ForEach(Outcome.allCases, id: \.self) { Pill($0.rawValue, $0.color) }
        Pill("ACTIVE", JobStatus.active.color)
        Pill("PAUSED", JobStatus.paused.color)
    }
    .padding()
}

#Preview("Stat Cards") {
    HStack(spacing: 12) {
        StatCard(label: "Total Jobs", value: "3")
        StatCard(label: "Active", value: "2", color: .green)
        StatCard(label: "Success Rate (24h)", value: "75%", color: .accentColor)
    }
    .padding().frame(width: 600)
}

#Preview("KV & Mono") {
    VStack(alignment: .leading) {
        Form { KV("Area path", #"Tickets\KPL\KAI"#) }.formStyle(.grouped)
        Mono(text: "{\n  \"query\": \"SELECT [System.Id] FROM WorkItems\"\n}")
    }
    .padding().frame(width: 500, height: 300)
}
