import SwiftUI
import UserNotifications

@main
struct JiraADOApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("jira-ado", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Sync Job") { model.open(.dashboard, [.create]) }
                    .keyboardShortcut("n")
                    .disabled(model.pat.isEmpty)
            }
            CommandMenu("Go") {
                Button("Search Pages and Jobs…") { model.paletteOpen = true }
                    .keyboardShortcut("k")
                    .disabled(model.pat.isEmpty)
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch model.setting(Setting.theme) {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

/// Closing the window only hides the app's UI, so syncs keep running; ⌘Q quits for real, asking first while runs are in flight.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // Set before launch finishes, so the click that launched the app is received too.
    func applicationWillFinishLaunching(_ notification: Notification) { UNUserNotificationCenter.current().delegate = self }

    func applicationDidFinishLaunching(_ notification: Notification) { AppModel.shared.start() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppModel.shared.openMainWindow?() }
        return true
    }

    // What the user sees in the app needn't wait in Notification Center.
    func applicationDidBecomeActive(_ notification: Notification) {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let n = AppModel.shared.running.count
        guard n > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(n) sync(s) still running. Quit anyway?"
        alert.informativeText = "They stop at the current issue; the next sync resumes from the last checkpoint."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) { AppLog.info("app quit") }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await MainActor.run {
            AppLog.info("notification clicked", ["id": id])
            AppModel.shared.openNotification(id)
        }
    }
}
