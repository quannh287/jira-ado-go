import AppKit
import SwiftUI

/// The menu bar icon: syncing, a failure count, or a check mark.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.menuStatus
        Image(systemName: s.symbol)
        if s.failing > 0 { Text("\(s.failing)") }
    }
}

/// The menu bar menu: status, each job's state, Sync Now, and the way back to the window.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.menuStatus.title)
        if !model.pat.isEmpty {
            Divider()
            ForEach(model.store.jobs) { j in
                Button(model.menuLine(j)) { show { model.openJob(j.id) } }
            }
            Menu("Sync Now") {
                ForEach(model.store.jobs.filter { $0.status == .active }) { j in
                    Button(j.name) { model.syncNow(j.id) }.disabled(model.running.contains(j.id))
                }
            }
            .disabled(!model.store.jobs.contains { $0.status == .active })
        }
        Divider()
        Button("Open JirAdo") { show {} }.keyboardShortcut("o")
        if !model.pat.isEmpty {
            Button("New Sync Job…") { show { model.open(.dashboard, [.create]) } }.keyboardShortcut("n")
        }
        if let u = model.availableUpdate {
            Button("Update to \(u.version)…") { show { model.updateSheet = u } }
        } else {
            Button("Check for Updates…") { show { Task { await model.checkForUpdates(manual: true) } } }
        }
        Divider()
        Button("Quit JirAdo") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    /// Brings the window forward: a menu bar app isn't active until asked.
    private func show(_ route: () -> Void) {
        route()
        openWindow(id: "main")
        NSApp.activate()
    }
}

#Preview("Menu Bar Label") {
    HStack(spacing: 24) {
        MenuBarLabel().previewModel()
        MenuBarLabel().previewModel(PreviewData.model(live: true))
    }
    .padding()
}

#Preview("Menu Bar Menu") {
    VStack(alignment: .leading) { MenuBarMenu() }.previewModel().padding().frame(width: 320)
}
