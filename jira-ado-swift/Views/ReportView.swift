import SwiftUI

private let liveID = -1

/// A job's runs on the left, the chosen one's tickets on the right; the run in flight shows live as its snapshots arrive.
struct ReportView: View {
    @Environment(AppModel.self) private var model
    let jobID: Int
    @State private var selected: Int?

    init(jobID: Int, runID: Int?) {
        self.jobID = jobID
        _selected = State(initialValue: runID ?? liveID)
    }

    private struct Entry: Identifiable {
        let run: Run
        let live: SyncProgress?
        var id: Int { live != nil ? liveID : run.id }
    }

    var body: some View {
        if let j = model.store.job(jobID) {
            let entries = (model.live[jobID].map { [Entry(run: $0.run, live: $0)] } ?? []) + model.store.runs(for: jobID).map { Entry(run: $0, live: nil) }
            if let cur = entries.first(where: { $0.id == selected }) ?? entries.first {
                HSplitView {
                    List(entries, selection: Binding(get: { cur.id }, set: { selected = $0 })) { e in row(e).tag(e.id) }
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                    RunDetail(job: j, run: cur.run, live: cur.live)
                        .frame(minWidth: 420, maxWidth: .infinity)
                }
                .navigationTitle("\(j.name) · Report")
            } else {
                ContentUnavailableView("No runs yet", systemImage: "clock", description: Text("Press Sync Now on the job page."))
                    .navigationTitle("\(j.name) · Report")
            }
        } else {
            ContentUnavailableView("Job not found", systemImage: "questionmark", description: Text("No job with ID \(jobID)."))
        }
    }

    private func row(_ e: Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if e.live != nil {
                    Text("Live").bold()
                    Spacer()
                    ProgressView().controlSize(.small)
                } else {
                    Text("Run #\(e.run.id)").bold()
                    Spacer()
                    if e.run.kind != .sync { Pill(kindLabel(e.run.kind), .secondary) }
                    Pill(e.run.status.rawValue, e.run.status.color)
                }
            }
            Text(e.live.map(progressText) ?? "\(e.run.started.short) · \(ago(e.run.started, Date()))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct RunDetail: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let run: Run
    let live: SyncProgress?

    var body: some View {
        let r = run, since = r.since.isEmpty ? "full backlog" : "since " + r.since
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let live {
                            Text("\(job.name) · Syncing").font(.title2.bold())
                            Text("started \(r.started.formatted(date: .omitted, time: .standard)) · \(progressText(live)) · \(since)")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("\(job.name) · Run #\(r.id)").font(.title2.bold())
                            if r.kind != .sync { Text(kindLabel(r.kind)).font(.callout.bold()).foregroundStyle(.tint) }
                            Text("\(r.started.formatted(date: .abbreviated, time: .standard)) · took \(fmtDuration(r.duration)) · \(r.tickets.count) tickets · \(since)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if live != nil {
                        IconButton("Cancel", systemImage: "stop.circle", role: .destructive,
                                   help: "Stops after the current issue; the next sync resumes from the last checkpoint") { model.cancelRun(job.id) }
                        ProgressView().controlSize(.small)
                    } else {
                        let n = r.failedKeys.count
                        if n > 0 && r.kind != .dryRun && job.status == .active && !model.running.contains(job.id) {
                            Button("Retry \(n) Failed", systemImage: "arrow.clockwise") { model.retryFailed(r) }
                                .help("Runs just these tickets again; the cursor isn't moved")
                        }
                        Pill(r.status.rawValue, r.status.color)
                    }
                }
                if let live {
                    if live.total > 0 { ProgressView(value: Double(live.done), total: Double(live.total)) } else { ProgressView().progressViewStyle(.linear) }
                }
                if r.kind == .dryRun {
                    banner("Dry run: nothing was written to ADO. Calls marked \"not sent\" are what a sync would send.", .accentColor)
                }
                if !r.error.isEmpty { banner(r.error, .red) }
                HStack(spacing: 12) {
                    ForEach(Outcome.allCases, id: \.self) { o in
                        StatCard(label: r.kind == .dryRun && (o == .created || o == .updated) ? "would be \(o.rawValue)" : o.rawValue,
                                 value: "\(r.count(o))", color: o.color)
                    }
                }
                Text("Tickets").bold()
                ForEach(groupTickets(r.tickets), id: \.self) { g in TicketGroupView(job: job, run: r, group: g) }
            }
            .padding(20)
        }
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A top-level ticket (or a parent not in the run) with its sub-tasks hanging off a rule.
private struct TicketGroupView: View {
    let job: Job
    let run: Run
    let group: TicketGroup
    @State private var folded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = group.parent {
                TicketView(job: job, ticket: run.tickets[p])
            } else {
                HStack(spacing: 8) {
                    Text(group.parentKey).font(.callout.monospaced().bold())
                    Text("parent not in this run").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
            if !group.children.isEmpty {
                let kids = group.children.map { run.tickets[$0] }
                let counts = Outcome.allCases.compactMap { o in
                    let n = kids.filter { $0.outcome == o }.count
                    return n > 0 ? "\(n) \(o.rawValue)" : nil
                }
                Button { folded.toggle() } label: {
                    Label(plural(kids.count, "sub-task") + " · " + counts.joined(separator: ", "), systemImage: folded ? "chevron.right" : "chevron.down")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
                if !folded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.children, id: \.self) { TicketView(job: job, ticket: run.tickets[$0]) }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 2) }
                    .padding(.leading, 22)
                }
            }
        }
    }
}

private struct TicketView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let ticket: Ticket
    @State private var open = false
    @State private var callsOpen = false

    var body: some View {
        let t = ticket
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 10) {
                links
                let msg = [t.workItemType, t.message].filter { !$0.isEmpty }.joined(separator: " · ")
                if !t.message.isEmpty { Text(msg).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !t.error.isEmpty {
                    Text(t.error.split(separator: "\n").first.map(String.init) ?? "").foregroundStyle(.red).textSelection(.enabled).lineLimit(3)
                }
                summary
                if !t.calls.isEmpty {
                    DisclosureGroup(isExpanded: $callsOpen) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(t.calls.enumerated()), id: \.offset) { _, c in CallView(call: c) }
                        }
                    } label: {
                        ToggleLabel(plural(t.calls.count, "ADO call"), isOn: $callsOpen)
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Text(t.key).font(.callout.monospaced().bold())
                Text(t.summary).lineLimit(1)
                Spacer()
                if t.adoID != 0 { Text("ADO #\(t.adoID)").font(.callout).foregroundStyle(.secondary) }
                Pill(t.outcome.rawValue, t.outcome.color)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { open.toggle() } }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    /// Opens the issue in Jira and the work item in ADO, in the browser.
    @ViewBuilder private var links: some View {
        let jira = issueURL(model.setting(Setting.jiraURL), ticket.key)
        let ado = workItemURL(model.setting(Setting.adoOrg), job.adoProject, ticket.adoID)
        if jira != nil || ado != nil {
            HStack(spacing: 16) {
                if let jira { Link("Open \(ticket.key) in Jira ↗", destination: jira).help(jira.absoluteString) }
                if let ado { Link("Open ADO #\(ticket.adoID) ↗", destination: ado).help(ado.absoluteString) }
            }
            .font(.callout)
        }
    }

    /// What reached ADO: fields with their values, then side effects.
    @ViewBuilder private var summary: some View {
        let (fields, notes) = synced(ticket.calls)
        if fields.isEmpty && notes.isEmpty {
            if ticket.outcome != .failed { Text("Nothing was written to ADO.").font(.callout).foregroundStyle(.secondary) }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(fields, id: \.self) { f in
                    GridRow {
                        Text(f.name).foregroundStyle(.secondary)
                        Text(f.value).lineLimit(1).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
            if !notes.isEmpty { Text(notes.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// A disclosure label that toggles on a click anywhere, not only on the arrow.
private struct ToggleLabel: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Text(title).contentShape(Rectangle()).onTapGesture { withAnimation { isOn.toggle() } }
    }
}

/// One call per line; its bodies behind Details.
private struct CallView: View {
    let call: APICall
    @State private var open = false

    var body: some View {
        let c = call, failed = c.status >= 400 || !c.error.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Pill(c.method, .accentColor)
                Text(shortURL(c.url)).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(fmtDuration(c.duration) + (c.retries > 0 ? " · \(c.retries) retries" : "")).font(.caption).foregroundStyle(.secondary)
                if c.status == 0 && c.error.isEmpty { Pill("not sent", .secondary) } else { Pill("\(c.status)", failed ? .red : .green) }
            }
            if !c.request.isEmpty || !c.response.isEmpty || !c.error.isEmpty {
                DisclosureGroup(isExpanded: $open) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !c.error.isEmpty { Text(c.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        if !c.request.isEmpty {
                            Text("Sent").font(.caption).foregroundStyle(.secondary)
                            Mono(text: c.request)
                        }
                        if !c.response.isEmpty {
                            Text("Response").font(.caption).foregroundStyle(.secondary)
                            Mono(text: c.response)
                        }
                    }
                } label: {
                    ToggleLabel("Details", isOn: $open)
                }
                .font(.caption)
            }
        }
    }
}

#Preview("Report") {
    NavigationStack { ReportView(jobID: 1, runID: nil) }.previewModel().frame(width: 1100, height: 720)
}

#Preview("Report · Dry Run") {
    NavigationStack { ReportView(jobID: 1, runID: 2) }.previewModel().frame(width: 1100, height: 600)
}

#Preview("Report · Failed Run") {
    NavigationStack { ReportView(jobID: 2, runID: 4) }.previewModel().frame(width: 1100, height: 600)
}

#Preview("Report · Live") {
    NavigationStack { ReportView(jobID: 1, runID: nil) }.previewModel(PreviewData.model(live: true)).frame(width: 1100, height: 720)
}

#Preview("Report · No Runs") {
    NavigationStack { ReportView(jobID: 3, runID: nil) }.previewModel().frame(width: 700, height: 400)
}

#Preview("Ticket") {
    TicketView(job: PreviewData.job, ticket: PreviewData.ticket("SE-140", "Crash when opening notifications", .failed, id: 4140, error: "TF401320: Rule Error"))
        .previewModel().padding().frame(width: 700)
}

#Preview("API Call") {
    CallView(call: APICall(method: "PATCH", url: "https://dev.azure.com/o/p/_apis/wit/workitems/4101?api-version=7.1", request: "[]", status: 200, response: "{}", retries: 2, duration: 1.3))
        .padding().frame(width: 600)
}
