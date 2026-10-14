import Foundation
import Testing
@testable import JirAdo

@Test(arguments: [("0.5.0", "0.4.0", true), ("0.10.0", "0.9.1", true), ("v1.0", "0.9.9", true), ("0.4.1", "0.4", true),
                  ("0.4.0", "0.4.0", false), ("0.4", "0.4.0", false), ("0.3.9", "0.4.0", false),
                  ("1.0.0", "1.0.0-beta", true), ("1.0.0-beta", "1.0.0", false), ("1.1.0-beta", "1.0.0", true)])
func versionComparison(a: String, b: String, newer: Bool) {
    #expect(isNewer(a, than: b) == newer)
}

private let page = URL(string: "https://github.com/o/r/releases/tag/v0.5.0")!
private let release = AppUpdate(version: "0.5.0", notes: "notes", download: page, page: page)

@Suite struct UpdateCheckTests {
    private func model(latest: AppUpdate?, error: Error? = nil) -> (AppModel, Counter) {
        let h = Harness()
        let calls = Counter()
        h.model.currentVersion = "0.4.0"
        h.model.latestRelease = {
            _ = calls.next()
            if let error { throw error }
            return latest
        }
        return (h.model, calls)
    }

    @Test func newerReleaseOpensTheSheet() async {
        let (m, _) = model(latest: release)
        await m.checkForUpdates(manual: false)
        #expect(m.updateSheet == release && m.availableUpdate == release)
        #expect(m.lastUpdateCheck == t0, "the check time is saved")
    }

    @Test func upToDateIsSilentUnlessManual() async {
        let (m, _) = model(latest: AppUpdate(version: "0.4.0", notes: "", download: page, page: page))
        await m.checkForUpdates(manual: false)
        #expect(m.updateSheet == nil && m.notice == nil)
        await m.checkForUpdates(manual: true)
        #expect(m.updateSheet == nil && m.notice == "JirAdo 0.4.0 is the latest version")
    }

    @Test func skippedVersionStaysQuietOnAutomaticChecks() async {
        let (m, _) = model(latest: release)
        m.skipUpdate(release)
        await m.checkForUpdates(manual: false)
        #expect(m.updateSheet == nil && m.availableUpdate == release, "the menu still offers it")
        await m.checkForUpdates(manual: true)
        #expect(m.updateSheet == release, "asking explicitly shows it again")
    }

    @Test func failuresAreSilentUnlessManual() async {
        let (m, _) = model(latest: nil, error: Failure("offline"))
        await m.checkForUpdates(manual: false)
        #expect(m.notice == nil && m.lastUpdateCheck == Date(timeIntervalSince1970: 0), "a failed check retries next tick")
        await m.checkForUpdates(manual: true)
        #expect(m.notice == "Couldn't check for updates: offline")
    }

    @Test func automaticChecksAreDailyAndCanBeTurnedOff() async {
        let (m, calls) = model(latest: nil)
        #expect(m.autoUpdateCheck && m.updateCheckDue, "on by default, and never checked yet")
        await m.checkForUpdates(manual: false)
        #expect(!m.updateCheckDue, "checked just now")
        m.now = { t0.addingTimeInterval(AppModel.updateInterval) }
        #expect(m.updateCheckDue, "a day later")
        m.setAutoUpdateCheck(false)
        #expect(!m.updateCheckDue && !m.autoUpdateCheck)
        #expect(calls.next() == 2, "one request so far")
    }

    @Test func defaultModelNeverAsksGitHub() async {
        let h = Harness()
        h.model.currentVersion = "0.0.1"
        await h.model.checkForUpdates(manual: false)
        #expect(h.model.availableUpdate == nil, "only the real launch wires GitHub")
    }

    @Test func downloadClosesTheSheet() {
        let (m, _) = model(latest: release)
        m.updateSheet = release
        m.skipUpdate(release)
        #expect(m.updateSheet == nil && m.setting(Setting.updateSkipped) == "0.5.0")
    }
}
