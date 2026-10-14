import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.secretsLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.pat.isEmpty {
                LoginView()
            } else {
                NavigationSplitView {
                    Sidebar()
                } detail: {
                    NavigationStack(path: $model.path) {
                        sectionView(model.section)
                            .navigationDestination(for: Route.self, destination: routeView)
                    }
                }
                .toolbar { Toolbar() }
                .sheet(isPresented: $model.paletteOpen) { Palette() }
            }
        }
        .overlay(alignment: .bottom) { Toast() }
        .onAppear { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
    }

    @ViewBuilder private func sectionView(_ s: Page) -> some View {
        switch s {
        case .dashboard: DashboardView()
        case .jobs: JobsView()
        case .logs: LogsView()
        case .mappings: MappingsView()
        case .settings: SettingsView()
        }
    }

    @ViewBuilder private func routeView(_ r: Route) -> some View {
        switch r {
        case .job(let id): JobView(id: id)
        case .edit(let id, let step): JobEditorView(editing: id, step: step)
        case .create: JobEditorView(editing: nil, step: 0)
        case .report(let id, let run): ReportView(jobID: id, runID: run)
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.open(s) } })) {
            Section("Jira → ADO") {
                ForEach(Page.allCases) { s in
                    Label(s.rawValue, systemImage: s.icon)
                        .badge(s == .jobs ? model.store.jobs.count : 0)
                        .tag(s)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 228)
        .safeAreaInset(edge: .bottom) { account }
    }

    private var account: some View {
        let name = model.setting(Setting.adoUser).isEmpty ? "ADO User" : model.setting(Setting.adoUser)
        return HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.callout.bold()).lineLimit(1)
                Text(model.setting(Setting.adoOrg)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Sign Out") { Task { await model.logout() } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("Account")
        }
        .padding(12)
    }
}

private struct Toolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.store.setSetting(Setting.theme, scheme == .dark ? "light" : "dark")
            } label: {
                Label(scheme == .dark ? "Light Theme" : "Dark Theme", systemImage: scheme == .dark ? "sun.max" : "moon")
            }
            .help(scheme == .dark ? "Light Theme" : "Dark Theme")
            Button { model.open(.dashboard, [.create]) } label: { Label("New Sync Job", systemImage: "plus") }
                .help("New Sync Job  ⌘N")
            Button { model.paletteOpen = true } label: { Label("Search", systemImage: "magnifyingglass") }
                .help("Search jobs and pages  ⌘K")
        }
    }
}

/// ⌘K: jump to a page or a job.
private struct Palette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Entry: Identifiable {
        let label: String, hint: String, go: () -> Void
        var id: String { label + hint }
    }

    private var entries: [Entry] {
        var all = Page.allCases.map { s in Entry(label: s.rawValue, hint: "Page") { model.open(s) } }
        all.append(Entry(label: "New Sync Job", hint: "Action") { model.open(.dashboard, [.create]) })
        all += model.store.jobs.map { j in Entry(label: j.name, hint: "\(j.jiraKey) → \(j.adoProject)") { model.openJob(j.id) } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { "\($0.label) \($0.hint)".lowercased().contains(q) }
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 8) {
            TextField("Search pages and jobs", text: $query)
                .accessibilityIdentifier("palette.search")
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let e = entries.first { pick(e) } }
            List(entries) { e in
                Button { pick(e) } label: {
                    HStack {
                        Text(e.label)
                        Spacer()
                        Text(e.hint).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay { if entries.isEmpty { Text("No matches").foregroundStyle(.secondary) } }
        }
        .padding(12)
        .frame(width: 460, height: 380)
    }

    private func pick(_ e: Entry) {
        e.go()
        dismiss()
    }
}

/// The last notice, at the bottom of the window for a few seconds.
private struct Toast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.notice {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 20)
                .onTapGesture { model.notice = nil }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

#Preview("App") {
    RootView().previewModel().frame(width: 1180, height: 760)
}

#Preview("App · Login") {
    RootView().previewModel(PreviewData.model(signedIn: false)).frame(width: 900, height: 600)
}

#Preview("App · Empty") {
    RootView().previewModel(PreviewData.model(empty: true)).frame(width: 1180, height: 760)
}

#Preview("Palette") {
    Palette().previewModel()
}

#Preview("Toast") {
    let model = PreviewData.model()
    model.notice = "Mobile bugs → ADO: 1 created, 2 updated, 1 skipped, 1 failed"
    return Color.clear.frame(width: 600, height: 120).overlay(alignment: .bottom) { Toast() }.environment(model)
}

#Preview("Sidebar") {
    NavigationSplitView { Sidebar() } detail: { Text("Detail") }.previewModel().frame(width: 700, height: 500)
}
