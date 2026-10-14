import SwiftUI

/// "A new version is available": the release notes and Download / Skip This Version / Later.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    let update: AppUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("jira-ado \(update.version) is available").font(.title3.bold())
                    Text("You have \(model.currentVersion). Download the new version, then drag it into Applications.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Release notes").font(.headline)
            ScrollView {
                Text(notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Skip This Version") { model.skipUpdate(update) }
                Link("View on GitHub", destination: update.page).font(.callout)
                Spacer()
                Button("Later") { model.updateSheet = nil }.keyboardShortcut(.cancelAction)
                Button("Download", systemImage: "arrow.down.circle") { model.downloadUpdate(update) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// GitHub's Markdown, inline styles and links kept, line breaks as written.
    private var notes: AttributedString {
        let text = update.notes.isEmpty ? "No release notes." : update.notes
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Settings → Updates: the version, automatic checks and Check Now.
struct UpdateSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Updates") {
            KV("Version", model.currentVersion)
            Toggle("Check for updates automatically", isOn: Binding(get: { model.autoUpdateCheck }, set: { model.setAutoUpdateCheck($0) }))
                .accessibilityIdentifier("settings.autoUpdate")
            HStack {
                Button("Check Now", systemImage: "arrow.triangle.2.circlepath") { Task { await model.checkForUpdates(manual: true) } }
                    .disabled(model.checkingUpdate)
                if model.checkingUpdate { ProgressView().controlSize(.small) }
                if let u = model.availableUpdate {
                    Button("Version \(u.version) available…") { model.updateSheet = u }.buttonStyle(.link)
                }
                Spacer()
                Text(model.lastUpdateCheck.timeIntervalSince1970 > 0 ? "Last checked " + ago(model.lastUpdateCheck, Date()) : "Never checked")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Once a day, jira-ado asks GitHub whether a newer release exists and offers to download it. Nothing is installed by itself.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

#Preview("Update Sheet") {
    let page = URL(string: "https://github.com/quannh287/jira-ado-go/releases/tag/v0.5.0")!
    UpdateSheet(update: AppUpdate(version: "0.5.0", notes: "## What's Changed\n- **Update check** in Settings by @quannh287\n- Faster syncs\n\n**Full Changelog**: v0.4.0...v0.5.0",
                                  download: page, page: page))
        .previewModel()
}

#Preview("Update Settings") {
    Form { UpdateSettings() }.formStyle(.grouped).previewModel().frame(width: 640)
}
