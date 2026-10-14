import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var jiraURL = ""
    @State private var jiraEmail = ""
    @State private var jiraToken = ""
    @State private var jql = ""
    @State private var keyField = ""
    @State private var checking = false
    @State private var result = ""

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { model.setting(Setting.theme).isEmpty ? "system" : model.setting(Setting.theme) },
                                                   set: { model.store.setSetting(Setting.theme, $0) })) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.theme")
                LabeledContent("App icon") {
                    HStack(spacing: 16) {
                        ForEach(AppIconOption.all) { o in
                            let chosen = o.id == AppIconOption.get(model.store.settings[Setting.appIcon]).id
                            Button { model.setAppIcon(o.id) } label: {
                                (o.image.map(Image.init(nsImage:)) ?? Image(systemName: "app"))
                                    .resizable().frame(width: 56, height: 56)
                                    .padding(3)
                                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(chosen ? Color.accentColor : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .help(o.name)
                            .accessibilityLabel(o.name)
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                }
                Text("The Dock icon while the app runs; Finder keeps the packaged icon.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Picker("When a run ends", selection: Binding(get: { model.notifyMode }, set: { model.store.setSetting(Setting.notify, $0.rawValue) })) {
                    Text("Every run").tag(NotifyMode.all)
                    Text("Failures only").tag(NotifyMode.failures)
                    Text("Off").tag(NotifyMode.off)
                }
                .pickerStyle(.segmented)
                LabeledContent("Test") {
                    Button("Send Test Notification") {
                        model.notifier.notify(id: AppModel.testNotificationID, title: "jira-ado", subtitle: "Notifications work",
                                              body: "Click to come back to Settings. Run notifications open their report.")
                    }
                }
                Text("A desktop notification with the counts; click it to open the run's report. macOS asks for permission the first time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Azure DevOps") {
                KV("Organization", model.setting(Setting.adoOrg))
                KV("Signed in as", model.setting(Setting.adoUser))
                Toggle("Remember PAT", isOn: Binding(get: { model.remember }, set: { on in Task { await model.toggleRemember(on) } }))
                Text("Keep the PAT in the macOS Keychain across launches. Off removes it; you stay signed in until you quit.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Jira key field", text: $keyField, prompt: Text(Defaults.jiraKeyField))
                    .help("ADO field holding \"KEY - id\"; the sync finds existing work items by it.")
            }
            Section("Jira") {
                TextField("Site URL", text: $jiraURL, prompt: Text("https://your-site.atlassian.net"))
                    .accessibilityIdentifier("settings.jiraURL")
                TextField("Email", text: $jiraEmail, prompt: Text("you@company.com"))
                SecureField("API token", text: $jiraToken).help("Stored in the macOS Keychain, never in the database.")
                TextField("Extra JQL", text: $jql, prompt: Text("issuetype in (Bug, Task)")).help("ANDed into every search.")
            }
            Section("Data") {
                LabeledContent("Previous app") { ImportLegacyButton() }
                Text("Brings in the Go app's jobs, run history, sync cursors, comment links and settings. Pick its jira-ado.db (and the Dev one too: its comment links stop comments being posted twice). The PAT and Jira token are already shared through the Keychain.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !AppLog.path.isEmpty {
                Section("Diagnostics") {
                    LabeledContent("Log file") {
                        Text(AppLog.path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AppLog.path)]) }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(AppLog.path, forType: .string)
                        }
                    }
                    Text("Every sync, HTTP failure and crash is logged here with its job, run and ticket; never tokens or PATs.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                if checking { ProgressView().controlSize(.small) }
                Text(result).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button("Test Jira", action: testJira).disabled(checking)
                Button("Save") { Task { await model.saveSettings(jiraURL: jiraURL, email: jiraEmail, jql: jql, keyField: keyField, token: jiraToken) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(checking)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            jiraURL = model.setting(Setting.jiraURL)
            jiraEmail = model.setting(Setting.jiraEmail)
            jql = model.setting(Setting.jqlExtra)
            keyField = model.setting(Setting.jiraKeyField).isEmpty ? Defaults.jiraKeyField : model.setting(Setting.jiraKeyField)
            jiraToken = model.jiraToken
        }
    }

    /// Checks what is typed, before it's saved.
    private func testJira() {
        var conn = model.connection()
        conn.jiraURL = trimSlash(jiraURL.trimmingCharacters(in: .whitespaces))
        conn.jiraEmail = jiraEmail.trimmingCharacters(in: .whitespaces)
        conn.jiraToken = jiraToken.trimmingCharacters(in: .whitespaces)
        checking = true
        result = ""
        Task {
            do { result = "Jira OK — signed in as " + (try await model.engine.checkJira(conn)) } catch { result = "Jira: " + describe(error) }
            checking = false
        }
    }
}

/// Opens the Go app's folder and imports the databases the user picks.
struct ImportLegacyButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Import from Go App…") {
            let panel = NSOpenPanel()
            panel.title = "Import jira-ado data"
            panel.message = "Choose the Go app's jira-ado.db files (Application Support/jira-ado and jira-ado Dev)."
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.directoryURL = AppModel.legacyDirectory
            if panel.runModal() == .OK { model.importLegacy(panel.urls) }
        }
    }
}

#Preview("Settings") {
    NavigationStack { SettingsView() }.previewModel().frame(width: 760, height: 1000)
}

#Preview("Import Button") {
    ImportLegacyButton().previewModel().padding()
}
