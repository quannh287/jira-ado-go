import SwiftUI

/// One editable "from → to" row of a rules table.
struct RulePair: Hashable {
    var from = ""
    var to = ""
}

/// The Mappings page's draft; nothing applies until Save.
struct MappingsForm: Equatable {
    var users: [UserPair] = []
    var types: [RulePair] = [], states: [RulePair] = [], taskStates: [RulePair] = [], priorities: [RulePair] = []
    var subtaskType = "", defaultType = ""

    init() {}

    init(rules r: Rules, users: [UserPair]) {
        self.users = users
        (types, states, taskStates, priorities) = (Self.pairs(r.types), Self.pairs(r.states), Self.pairs(r.taskStates), Self.pairs(r.priorities))
        (subtaskType, defaultType) = (r.subtaskType, r.defaultType)
    }

    static func pairs(_ m: [String: String]) -> [RulePair] { m.map { RulePair(from: $0.key, to: $0.value) }.sorted { $0.from < $1.from } }

    static func map(_ ps: [RulePair]) -> [String: String] {
        var m: [String: String] = [:]
        for p in ps {
            let k = p.from.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { m[k] = p.to.trimmingCharacters(in: .whitespaces) }
        }
        return m
    }

    var rules: Rules {
        Rules(types: Self.map(types), subtaskType: subtaskType.trimmingCharacters(in: .whitespaces), defaultType: defaultType.trimmingCharacters(in: .whitespaces),
              states: Self.map(states), taskStates: Self.map(taskStates), priorities: Self.map(priorities))
    }

    /// Why the draft can't be saved, or nil.
    var error: String? {
        if users.contains(where: { $0.jira.trimmingCharacters(in: .whitespaces).isEmpty || !$0.adoEmail.contains("@") }) {
            return "Each shared user needs a Jira user and an ADO email."
        }
        for (name, rows) in [("Work item types", types), ("Backlog item states", states), ("Task states", taskStates), ("Priorities", priorities)] {
            var seen = Set<String>()
            for p in rows {
                let k = p.from.trimmingCharacters(in: .whitespaces).lowercased()
                if k.isEmpty || p.to.trimmingCharacters(in: .whitespaces).isEmpty { return name + ": fill in both sides of every row." }
                if !seen.insert(k).inserted { return "\(name): \"\(p.from)\" is mapped twice." }
            }
        }
        if priorities.contains(where: { !["1", "2", "3", "4"].contains($0.to.trimmingCharacters(in: .whitespaces)) }) {
            return "Priorities: ADO priority is 1, 2, 3 or 4."
        }
        if subtaskType.trimmingCharacters(in: .whitespaces).isEmpty || defaultType.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Work item types: set the type for sub-tasks and for everything else."
        }
        return nil
    }

    /// Adds every job's user mapping whose Jira user isn't here yet; returns how many.
    mutating func importUsers(from jobs: [Job]) -> Int {
        var have = Set(users.map { $0.jira.trimmingCharacters(in: .whitespaces).lowercased() }), added = 0
        for u in jobs.flatMap(\.filters.users) {
            let k = u.jira.trimmingCharacters(in: .whitespaces).lowercased()
            if !k.isEmpty, have.insert(k).inserted {
                users.append(u)
                added += 1
            }
        }
        return added
    }
}

struct MappingsView: View {
    @Environment(AppModel.self) private var model
    @State private var form = MappingsForm()
    @State private var loaded = false

    var body: some View {
        let cat = model.catalog.cat, err = form.error
        // States of the backlog types this page maps to: the default, the overrides, and Scrum's usual two.
        let backlog = [form.defaultType, typePBI, "Bug"] + form.types.map(\.to).filter { !isTask($0) }
        Form {
            if model.catalog.loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading statuses and types from Jira and ADO…").foregroundStyle(.secondary)
                }
            } else if !model.catalog.error.isEmpty {
                Text("Some lists couldn't load, so those fields take typed values: " + model.catalog.error)
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            Section {
                ForEach(form.users.indices, id: \.self) { i in
                    HStack {
                        TextField("Jira user", text: $form.users[i].jira, prompt: Text("Jira email or name")).labelsHidden()
                        Text("→").foregroundStyle(.secondary)
                        TextField("ADO email", text: $form.users[i].adoEmail, prompt: Text("name@company.com")).labelsHidden()
                        IconButton("Remove", systemImage: "minus.circle", role: .destructive) { form.users.remove(at: i) }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add User", systemImage: "plus") { form.users.append(UserPair()) }.help("Adds an empty Jira → ADO user row")
                    Button("Import from Jobs", systemImage: "person.2") { model.show("Imported \(form.importUsers(from: model.store.jobs)) users; Save to keep them") }
                        .help("Adds every job's user mapping that isn't here yet")
                }
            } header: {
                header("Users", "Jira user (email or display name) → ADO email, for Assigned To and Created By. A job's own user mapping wins over this one.")
            }
            Section {
                ChoiceField(label: "Sub-tasks", value: $form.subtaskType, options: cat.adoTypes, hint: typeTask)
                ChoiceField(label: "Everything else", value: $form.defaultType, options: cat.adoTypes, hint: typePBI)
                PairRows(rows: $form.types, from: cat.jiraTypes, to: cat.adoTypes, fromHint: "Jira issue type (e.g. Bug)", toHint: "ADO type (e.g. Bug)", add: "Add Type Override")
            } header: { header("Work item types", "Which ADO work item type a Jira issue becomes.") }
            Section {
                PairRows(rows: $form.states, from: cat.jiraStatuses, to: cat.statesFor(backlog), fromHint: "Jira status", toHint: "ADO state", add: "Add State")
            } header: {
                header("States: backlog items", "Jira status → ADO state for PBIs, Bugs and other non-Task types. Unmapped statuses use the type's first state (New).")
            }
            Section {
                PairRows(rows: $form.taskStates, from: cat.jiraStatuses, to: cat.statesFor([typeTask, form.subtaskType]), fromHint: "Jira status", toHint: "ADO state", add: "Add State")
            } header: { header("States: tasks", "Jira status → ADO state for Tasks. Unmapped statuses use To Do.") }
            Section {
                PairRows(rows: $form.priorities, from: cat.jiraPriorities, to: ["1", "2", "3", "4"], fromHint: "Jira priority", toHint: "1–4", add: "Add Priority")
            } header: { header("Priorities", "Jira priority → ADO priority 1 (highest) to 4. Unmapped priorities use 4.") }
        }
        .formStyle(.grouped)
        .navigationTitle("Mappings")
        .navigationSubtitle("Shared by every job")
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let err { Text(err).font(.callout).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                IconButton("Refresh Options", systemImage: "arrow.clockwise",
                           help: "Refresh Options: reload Jira statuses, issue types and priorities, and ADO types and states") { Task { await model.loadCatalog() } }
                    .disabled(model.catalog.loading)
                IconButton("Reset Rules to Defaults", systemImage: "arrow.counterclockwise",
                           help: "Reset Rules to Defaults: the source app's rules; shared users stay") { form = MappingsForm(rules: .defaults, users: form.users) }
                IconButton("Revert", systemImage: "arrow.uturn.backward", help: "Revert: discard unsaved changes", action: load)
                Button("Save", action: save).buttonStyle(.borderedProminent).disabled(err != nil).help("Saves these mappings")
            }
            .padding(12)
            .background(.bar)
        }
        .onAppear {
            if !loaded { load() }
            if !model.catalog.tried { Task { await model.loadCatalog() } }  // once per launch; Refresh Options reloads
        }
    }

    private func header(_ title: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(desc).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() {
        loaded = true
        form = MappingsForm(rules: model.store.rules, users: model.store.sharedUsers)
    }

    private func save() {
        model.store.setSharedUsers(form.users)
        model.store.setRules(form.rules)
        load()  // show what the next sync will use, defaults filled in
        model.show("Mappings saved; the next sync uses them")
    }
}

/// Edits a from → to table in place; each side is a picker when its options are known.
private struct PairRows: View {
    @Binding var rows: [RulePair]
    let from: [String], to: [String]
    let fromHint: String, toHint: String, add: String

    var body: some View {
        ForEach(rows.indices, id: \.self) { i in
            HStack {
                ChoiceField(label: fromHint, value: $rows[i].from, options: from, hint: fromHint).labelsHidden()
                Text("→").foregroundStyle(.secondary)
                ChoiceField(label: toHint, value: $rows[i].to, options: to, hint: toHint).labelsHidden()
                IconButton("Remove", systemImage: "minus.circle", role: .destructive) { rows.remove(at: i) }
                    .buttonStyle(.borderless)
            }
        }
        Button(add, systemImage: "plus") { rows.append(RulePair(from: from.first ?? "", to: to.first ?? "")) }  // a picker needs a value from its list
    }
}

/// A picker over options, or a text field while the options are unknown.
/// A saved value missing from the list stays selectable, so loading the lists never changes a rule.
struct ChoiceField: View {
    let label: String
    @Binding var value: String
    let options: [String]
    let hint: String

    var body: some View {
        if options.isEmpty {
            TextField(label, text: $value, prompt: Text(hint))
        } else {
            Picker(label, selection: $value) {
                ForEach(options + (value.isEmpty || options.contains(value) ? [] : [value]), id: \.self) { Text($0) }
            }
        }
    }
}

#Preview("Mappings") {
    NavigationStack { MappingsView() }.previewModel().frame(width: 900, height: 900)
}

#Preview("Mappings · Lists Unavailable") {
    let model = PreviewData.model()
    model.catalog = CatalogState(tried: true, error: "jira priorities: HTTP 401")
    return NavigationStack { MappingsView() }.environment(model).frame(width: 900, height: 700)
}

#Preview("Choice Field") {
    @Previewable @State var value = "Custom"
    Form {
        ChoiceField(label: "Picker", value: $value, options: ["Bug", "Task"], hint: "type")
        ChoiceField(label: "Typed", value: $value, options: [], hint: "type")
    }
    .formStyle(.grouped).frame(width: 400)
}
