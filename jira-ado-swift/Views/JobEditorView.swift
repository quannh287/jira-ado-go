import SwiftUI

/// The 4-step wizard: creates a job (editing nil) or edits one, which can save from any step once every step is valid.
struct JobEditorView: View {
    @Environment(AppModel.self) private var model
    let editing: Int?
    @State private var step: Int
    @State private var job = Job(type: .manual)
    @State private var loaded = false
    @State private var checking = false
    @State private var checkProblems: [String] = []
    @State private var checkError = ""
    @State private var checkOK = false

    static let steps = ["Basic", "Field Mapping", "Filters", "Review"]

    init(editing: Int?, step: Int) {
        self.editing = editing
        _step = State(initialValue: step)
    }

    var body: some View {
        if let editing, model.store.job(editing) == nil {
            ContentUnavailableView("Job not found", systemImage: "questionmark", description: Text("No job with ID \(editing)."))
        } else {
            content.onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let editing, let j = model.store.job(editing) { job = j }  // edited as a copy until Save
    }

    private var content: some View {
        let err = stepError(step), reachable = firstInvalid
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, s in
                    if i > 0 { Rectangle().fill(.separator).frame(width: 24, height: 1) }
                    Button { step = i } label: {
                        HStack(spacing: 6) {
                            Text(i < step ? "✓" : "\(i + 1)")
                                .font(.caption.bold())
                                .frame(width: 20, height: 20)
                                .background(stepColor(i).opacity(0.15), in: Circle())
                            Text(s).fontWeight(i == step ? .bold : .regular)
                        }
                        .foregroundStyle(stepColor(i))
                    }
                    .buttonStyle(.plain)
                    .disabled(i > reachable)  // steps up to the first invalid one can be clicked
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            Form {
                switch step {
                case 0: basic
                case 1: mapping
                case 2: filters
                default: review
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { model.path.removeLast() }
                Spacer()
                if let err { Text(err).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                Button("Back") { step -= 1 }.disabled(step == 0)
                if step < Self.steps.count - 1 {
                    Button("Next") { step += 1 }.disabled(err != nil).keyboardShortcut(.defaultAction)
                }
                if editing != nil {
                    Button("Save Changes", action: save).buttonStyle(.borderedProminent).disabled(reachable < Self.steps.count)
                } else if step == Self.steps.count - 1 {
                    Button("Create Job", action: create).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .navigationTitle(editing == nil ? "New Sync Job" : "Edit \(job.name)")
        .navigationSubtitle(editing == nil ? "Jira → ADO" : "\(job.jiraKey) → \(job.adoProject)")
    }

    private func stepColor(_ i: Int) -> Color { i == step ? .accentColor : i < step ? .green : .secondary }

    // MARK: Steps

    @ViewBuilder private var basic: some View {
        TextField("Job name", text: $job.name, prompt: Text("Mobile bugs → ADO"))
            .accessibilityIdentifier("job.name")
        TextField("Jira project key", text: $job.jiraKey, prompt: Text("SE"))
            .disabled(editing != nil)
            .help(editing != nil ? "Fixed after creation: the sync cursor and ADO links belong to this project." : "")
            .accessibilityIdentifier("job.jiraKey")
        TextField("ADO project ID", text: $job.adoProject, prompt: Text("kai-mobile"))
            .accessibilityIdentifier("job.adoProject")
        KV("Direction", "Jira → ADO")
        Picker("Sync type", selection: $job.type) {
            ForEach(SyncType.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
        Text(["Manual": "Runs only when you press Sync Now.", "Scheduler": "Runs on a schedule."][job.type.rawValue] ?? "")
            .font(.callout).foregroundStyle(.secondary)
        if job.type == .scheduler {
            Picker("Run every", selection: Binding(get: { Int(job.filters.every / 60) }, set: { job.filters.everyMinutes = $0 })) {
                ForEach(Array(everyMinutes.enumerated()), id: \.offset) { i, m in Text(everyLabels[i]).tag(m) }
                if !everyMinutes.contains(Int(job.filters.every / 60)) { Text(fmtEvery(job.filters.every)).tag(Int(job.filters.every / 60)) }
            }
            Text("Counted from the last run, while the app is open (also in the background).").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var mapping: some View {
        Section {
            ForEach(job.mappings.indices, id: \.self) { i in
                HStack {
                    Picker("Jira → ADO field", selection: $job.mappings[i]) {
                        ForEach(Field.supported, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    IconButton("Remove", systemImage: "minus.circle", role: .destructive) { job.mappings.remove(at: i) }
                        .buttonStyle(.borderless)
                }
            }
            if job.mappings.isEmpty {
                Text("No fields mapped yet. Start with Smart Defaults or add a pair.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(job.mappings.count) field pairs")
                    Text("Only mapped ADO fields are written; title, area, iteration and the Jira key always are.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Smart Defaults (\(Field.supported.count))", systemImage: "wand.and.stars") {
                    for p in Field.supported where !job.mappings.contains(where: { $0.ado == p.ado }) { job.mappings.append(p) }
                }
                .help("Every field the sync can write")
                Button("Add Pair", systemImage: "plus") { if let p = unmappedPair { job.mappings.append(p) } }.disabled(unmappedPair == nil)
                    .help("Adds the next field that isn't mapped yet")
            }
        }
    }

    private var unmappedPair: FieldPair? { Field.supported.first { p in !job.mappings.contains { $0.ado == p.ado } } }

    @ViewBuilder private var filters: some View {
        Section {
            Toggle("Sync comments", isOn: $job.filters.syncComments)
            Text("Copy Jira comments to the ADO discussion; edits patch the same comment.").font(.callout).foregroundStyle(.secondary)
            Toggle("User filter", isOn: $job.filters.userFilter)
            Text("Only sync issues whose assignee is listed below, or, with no list, maps to an ADO email.").font(.callout).foregroundStyle(.secondary)
            if job.filters.userFilter {
                TextField("Assignees", text: $job.filters.assignees, prompt: Text("Mapped users"))
                    .help("Jira emails or display names, comma-separated.")
            }
            TextField("Area path", text: $job.filters.areaPath, prompt: Text(Defaults.areaPath))
            Picker("Iteration", selection: $job.filters.autoPaths) {
                Text("Follow Jira sprint").tag(true)
                Text("Fixed path").tag(false)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            if job.filters.autoPaths {
                TextField("Sprint root", text: $job.filters.sprintRoot, prompt: Text(Defaults.sprintRoot))
                TextField("Anchor sprint", value: $job.filters.anchorSprint, format: .number)
                TextField("Anchor date", text: $job.filters.anchorDate, prompt: Text("2026-06-01"))
                    .help("Monday the anchor sprint starts; one ADO sprint per week after it.")
                KV("In active Jira sprint", job.paths(at: Date()).iteration)
                KV("Otherwise (backlog)", job.backlogPath)
            } else {
                TextField("Iteration path", text: $job.filters.iteration, prompt: Text(#"Tickets\Sprint 42"#))
            }
            checkRow
        }
        Section {
            ForEach(job.filters.users.indices, id: \.self) { i in
                HStack {
                    TextField("Jira user", text: $job.filters.users[i].jira, prompt: Text("Jira email or name")).labelsHidden()
                    Text("→").foregroundStyle(.secondary)
                    TextField("ADO email", text: $job.filters.users[i].adoEmail, prompt: Text("name@company.com")).labelsHidden()
                    IconButton("Remove", systemImage: "minus.circle", role: .destructive) { job.filters.users.remove(at: i) }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            HStack {
                VStack(alignment: .leading) {
                    Text("User mapping")
                    Text("Jira user (email or display name) → ADO email, for Assigned To and Created By.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add User", systemImage: "plus") { job.filters.users.append(UserPair()) }.help("Adds an empty Jira → ADO user row")
            }
        }
    }

    /// The engine's preflight on the draft: the paths and the Sprint field a sync needs.
    private var checkRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Check in ADO", systemImage: "checkmark.seal", action: check)
                    .disabled(checking)
                    .help("Looks up the area and iteration paths in ADO and the Sprint field in Jira")
                if checking {
                    ProgressView().controlSize(.small)
                } else if !checkError.isEmpty {
                    Text(checkError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                } else if checkOK {
                    Text("✓ Paths exist in ADO; ready to sync").font(.callout).foregroundStyle(.green)
                }
            }
            ForEach(checkProblems, id: \.self) { Text("• " + $0).font(.callout).foregroundStyle(.red) }
        }
    }

    private func check() {
        let conn = model.connection(), job = model.effectiveJob(job)
        checking = true
        (checkProblems, checkError, checkOK) = ([], "", false)
        Task {
            do {
                let problems = try await model.engine.check(conn, job)
                checkProblems = problems
                checkOK = problems.isEmpty
            } catch { checkError = describe(error) }
            checking = false
        }
    }

    @ViewBuilder private var review: some View {
        Section("Basic") {
            KV("Name", job.name)
            KV("Jira project", job.jiraKey.uppercased())
            KV("ADO project", job.adoProject)
            KV("Direction", "Jira → ADO")
            KV("Sync type", syncTypeLabel(job))
        }
        Section("Field mapping") {
            ForEach(job.mappings, id: \.self) { KV($0.jira, $0.ado) }
        }
        Section("Filters") { FiltersRows(job: job) }
        if editing == nil {
            Text("The job starts ACTIVE. Run it from its page with Sync Now.").font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Validation and saving

    private func stepError(_ i: Int) -> String? { job.wizardError(step: i) }

    /// The first step that can't be left, or steps.count.
    private var firstInvalid: Int { job.firstInvalidStep }

    private func create() {
        var j = job
        j.name = j.name.trimmingCharacters(in: .whitespaces)
        j.jiraKey = j.jiraKey.trimmingCharacters(in: .whitespaces).uppercased()
        j.adoProject = j.adoProject.trimmingCharacters(in: .whitespaces)
        model.store.addJob(j)
        model.show("Created \(j.name)")
        model.open(.dashboard)
    }

    private func save() {
        var j = job
        j.name = j.name.trimmingCharacters(in: .whitespaces)
        j.adoProject = j.adoProject.trimmingCharacters(in: .whitespaces)
        model.store.updateJob(j)
        model.show("Saved \(j.name)")
        model.path.removeLast()
    }
}

extension Job {
    /// Why the user can't leave step i, or nil when they can.
    func wizardError(step i: Int) -> String? {
        let blank = { (s: String) in s.trimmingCharacters(in: .whitespaces).isEmpty }
        switch i {
        case 0:
            if blank(name) { return "Enter a job name." }
            if blank(jiraKey) { return "Enter the Jira project key." }
            if blank(adoProject) { return "Enter the ADO project ID." }
        case 1:
            if mappings.isEmpty { return "Map at least one field." }
            var seen = Set<String>()
            for m in mappings {
                if !Field.supported.contains(m) { return m.label + " isn't a pair the sync can write." }
                if !seen.insert(m.ado).inserted { return m.ado + " is mapped twice." }
            }
        case 2:
            let f = filters
            if f.users.contains(where: { blank($0.jira) || !$0.adoEmail.contains("@") }) {
                return "Each user mapping needs a Jira user and an ADO email."
            }
            if blank(f.areaPath) { return "Enter the ADO area path." }
            if !f.autoPaths && blank(f.iteration) { return "Enter a fixed iteration path, or derive it from the weekly sprint." }
            if f.autoPaths && blank(f.sprintRoot) { return "Enter the sprint root path." }
            if f.autoPaths && parseDay(f.anchorDate) == nil { return "Enter the anchor date as yyyy-mm-dd." }
        default: break
        }
        return nil
    }

    /// The first wizard step that can't be left, or the number of steps.
    var firstInvalidStep: Int { JobEditorView.steps.indices.first { wizardError(step: $0) != nil } ?? JobEditorView.steps.count }
}

#Preview("New Job") {
    NavigationStack { JobEditorView(editing: nil, step: 0) }.previewModel().frame(width: 900, height: 640)
}

#Preview("Edit · Mapping") {
    NavigationStack { JobEditorView(editing: 1, step: 1) }.previewModel().frame(width: 900, height: 700)
}

#Preview("Edit · Filters") {
    NavigationStack { JobEditorView(editing: 1, step: 2) }.previewModel().frame(width: 900, height: 800)
}

#Preview("Edit · Review") {
    NavigationStack { JobEditorView(editing: 1, step: 3) }.previewModel().frame(width: 900, height: 800)
}
