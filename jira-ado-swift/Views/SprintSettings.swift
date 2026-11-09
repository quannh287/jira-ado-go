import SwiftUI

/// Which ADO projects the Sprint page plans, and how much of the week each one gets.
struct SprintSettings: View {
    @Environment(AppModel.self) private var model
    @State private var config = SprintConfig()
    @State private var loaded = false

    var body: some View {
        Section("Sprint planning") {
            TextField("ADO email", text: $config.adoEmail, prompt: Text("you@company.com"))
                .accessibilityIdentifier("sprint.email")
            TextField("Work week (hours)", value: $config.workweekHours, format: .number)
                .accessibilityIdentifier("sprint.workweek")
            LabeledContent("Budget") {
                Text(config.projects.map { "\($0.name) \(hoursText($0.budget(config.workweekHours)))" }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }

            ForEach($config.projects) { $p in
                DisclosureGroup(p.name.isEmpty ? "New project" : "\(p.name) — \(p.effortPct)%") {
                    TextField("Name", text: $p.name)
                    TextField("ADO project", text: $p.adoProject)
                    TextField("Area path", text: $p.areaPath, prompt: Text(#"Tickets\KPL\KAI"#))
                    TextField("Iteration base", text: $p.iterationBase, prompt: Text(#"Tickets\Weekly Sprint"#))
                    TextField("Effort %", value: $p.effortPct, format: .number)
                    activities(p.name)
                    Button("Remove project", role: .destructive) { config.projects.removeAll { $0.id == p.id } }
                }
            }
            Button("Add project", systemImage: "plus") {
                config.projects.append(SprintProject(adoProject: "Tickets", iterationBase: Defaults.sprintRoot))
            }

            HStack {
                Text("The planning skill's YAML seeded this once; it is edited here now.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Save sprint config") { model.store.setSprintConfig(config) }
                    .disabled(config == model.sprintConfig)
            }
        }
        .onAppear {
            guard !loaded else { return }  // re-entering the page must not drop unsaved edits
            config = model.sprintConfig
            loaded = true
        }
    }

    /// Ceremonies created automatically each sprint; parity keeps planning and retro in alternate weeks.
    @ViewBuilder private func activities(_ project: String) -> some View {
        let index = config.activities.firstIndex { $0.project == project }
        DisclosureGroup("Activity tasks (\(index.map { config.activities[$0].items.count } ?? 0))") {
            if let i = index {
                TextField("Parent work item", value: $config.activities[i].parentID, format: .number)
                ForEach($config.activities[i].items) { $item in
                    VStack(alignment: .leading) {
                        TextField("Title", text: $item.title, prompt: Text("[KAI] … {sprint_name} | Sprint Planning"))
                        HStack {
                            Picker("Day", selection: $item.priority) {
                                ForEach(1...4, id: \.self) { Text("P\($0) · \(weekdayNames[priorityOffset($0)])").tag($0) }
                            }
                            Picker("Weeks", selection: $item.parity) {
                                ForEach(Parity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Button("Remove", role: .destructive) { config.activities[i].items.removeAll { $0.id == item.id } }
                        }
                    }
                }
                Button("Add activity", systemImage: "plus") { config.activities[i].items.append(ActivityItem()) }
            } else {
                Button("Add activity", systemImage: "plus") {
                    config.activities.append(ActivityGroup(project: project, items: [ActivityItem()]))
                }
            }
        }
    }
}

#Preview("Sprint settings") {
    Form { SprintSettings() }.formStyle(.grouped).previewModel().frame(width: 760, height: 600)
}
