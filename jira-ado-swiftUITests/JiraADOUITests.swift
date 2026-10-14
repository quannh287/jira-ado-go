import XCTest

/// Drives the app as a user would. The app starts with -ui-testing: an in-memory store, the fake engine
/// (no Jira or ADO calls), demo jobs and no Keychain, so every test starts from the same state.
final class JiraADOUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    @discardableResult
    private func launch(signedIn: Bool = true, empty: Bool = false) -> XCUIApplication {
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + (signedIn ? ["-signed-in"] : []) + (empty ? ["-empty"] : [])
        app.launch()
        app.activate()
        return app
    }

    private func wait(_ e: XCUIElement, _ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(e) didn't appear", file: file, line: line)
    }

    /// SwiftUI on macOS exposes Text as a static text whose value, not label, holds the string.
    private func text(_ s: String, in root: XCUIElement? = nil) -> XCUIElement {
        (root ?? app).staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", s, s)).firstMatch
    }

    private func textStarting(_ s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", s, s)).firstMatch
    }

    /// Buttons by label: toolbar buttons don't carry their title as an identifier.
    private func button(_ label: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch }

    private func enabled(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let ok = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: e)
        XCTAssertEqual(XCTWaiter().wait(for: [ok], timeout: 10), .completed, "\(e) didn't become enabled", file: file, line: line)
    }

    private func field(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func type(_ id: String, _ value: String, replacing: Bool = false) {
        let f = field(id)
        wait(f)
        f.click()
        if replacing { f.typeKey("a", modifierFlags: .command) }
        f.typeText(value)
    }

    private func sidebar(_ page: String) {
        let item = text(page, in: app.outlines["Sidebar"])
        wait(item)
        item.click()
    }

    /// A row of a SwiftUI Table, which macOS exposes as an outline.
    private func row(_ s: String) -> XCUIElement { text(s, in: app.outlines.element(boundBy: 1)) }

    /// Clicks until `then` shows: a click can land before a freshly shown table takes input.
    private func click(_ e: XCUIElement, until then: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        wait(e, file: file, line: line)
        for _ in 0..<3 where !then.exists {
            e.click()
            if then.waitForExistence(timeout: 3) { return }
        }
        XCTAssertTrue(then.exists, "\(then) didn't appear after clicking \(e)", file: file, line: line)
    }

    private func openJob(_ name: String) { click(row(name), until: button("Sync Now")) }

    private func tab(_ name: String) {
        let t = field("job.tabs").radioButtons[name].firstMatch
        wait(t)
        t.click()
    }

    /// The full accessibility tree goes to the log with any failure, to fix queries without guessing.
    override func record(_ issue: XCTIssue) {
        if let app { print("UI TREE at failure:\n\(app.debugDescription)") }
        super.record(issue)
    }

    // MARK: Sign-in

    func testLoginRejectsABadTokenThenSignsIn() {
        launch(signedIn: false)
        type("login.org", "my-org")
        type("login.pat", "short")
        let pat = field("login.pat")
        button("Sign In").click()
        wait(text("ADO rejected the personal access token"))

        pat.click()
        pat.typeKey("a", modifierFlags: .command)
        pat.typeText(String(repeating: "x", count: 24))
        button("Sign In").click()
        wait(text("Total Jobs"), 8)
        XCTAssertTrue(text("Demo User").exists, "the sidebar shows the signed-in user")
    }

    func testSignOutReturnsToLogin() {
        launch()
        let account = app.menuButtons["Account"].firstMatch
        wait(account)
        account.click()
        app.menuItems["Sign Out"].click()
        wait(button("Sign In"))
    }

    // MARK: Dashboard and jobs

    func testDashboardShowsStatsAndJobs() {
        launch()
        wait(text("Total Jobs"))
        for job in ["Mobile bugs → ADO", "Web platform stories", "Support escalations"] {
            wait(row(job))
        }
        XCTAssertTrue(text("PAUSED").exists)
    }

    func testEmptyDashboardOffersToCreateOrImport() {
        launch(empty: true)
        wait(text("No sync jobs yet"))
        XCTAssertTrue(button("Import from Go App…").exists)
        click(field("empty.newJob"), until: field("job.name"))
    }

    func testCreateJobWithTheWizard() {
        launch(empty: true)
        wait(text("No sync jobs yet"))
        app.typeKey("n", modifierFlags: .command)
        wait(field("job.name"))
        XCTAssertFalse(button("Next").isEnabled, "step 1 needs a name, a Jira key and an ADO project")
        type("job.name", "UI job")
        type("job.jiraKey", "ui")
        type("job.adoProject", "kai")
        button("Next").click()

        wait(text("Map at least one field."))
        button("Smart Defaults (11)").click()
        enabled(button("Next"))
        button("Next").click()

        wait(button("Check in ADO"))
        button("Check in ADO").click()
        wait(text("✓ Paths exist in ADO; ready to sync"))
        button("Next").click()

        wait(text("The job starts ACTIVE. Run it from its page with Sync Now."))
        XCTAssertTrue(text("UI").exists, "the Jira key is upper-cased")
        button("Create Job").click()
        wait(row("UI job"))
    }

    func testEditJobSavesChanges() {
        launch()
        openJob("Mobile bugs → ADO")
        button("Edit Job").click()
        wait(field("job.name"))
        XCTAssertFalse(field("job.jiraKey").isEnabled, "the Jira key is fixed after creation")
        type("job.name", "Mobile renamed", replacing: true)
        button("Save Changes").click()
        wait(button("Sync Now"))
        tab("Activity Log")
        wait(text("Job settings changed"))
    }

    func testPauseAndResume() {
        launch()
        openJob("Mobile bugs → ADO")
        button("Pause").click()
        wait(button("Resume"))
        XCTAssertFalse(button("Sync Now").isEnabled, "only ACTIVE jobs can sync")
        button("Resume").click()
        wait(button("Pause"))
        XCTAssertTrue(button("Sync Now").isEnabled)
    }

    func testDeleteJob() {
        launch()
        openJob("Support escalations")
        tab("Settings")
        button("Delete Job…").click()
        let confirm = app.sheets.buttons["Delete"].firstMatch.exists ? app.sheets.buttons["Delete"].firstMatch : button("Delete")
        wait(confirm)
        confirm.click()
        wait(text("Deleted Support escalations"))
        XCTAssertFalse(row("Support escalations").exists)
    }

    func testJobTabs() {
        launch()
        openJob("Mobile bugs → ADO")
        for (tab, expected) in [("Field Mappings", "System.Title"), ("Filters", "Sync comments"), ("Sync History", "#1"), ("Activity Log", "Job created")] {
            self.tab(tab)
            wait(text(expected))
        }
    }

    // MARK: Runs and reports

    func testSyncNowShowsTheReport() {
        launch()
        openJob("Mobile bugs → ADO")
        button("Sync Now").click()
        enabled(button("Sync Now"))  // the fake run takes a moment, then the job can sync again
        button("View Report").click()
        wait(text("Tickets"))
        wait(text("created"))
        XCTAssertTrue(textStarting("Mobile bugs → ADO · Run #").exists)
    }

    func testDryRunIsMarkedInTheReport() {
        launch()
        openJob("Mobile bugs → ADO")
        button("Dry Run").click()
        enabled(button("Sync Now"))
        tab("Sync History")
        let newest = app.outlines.element(boundBy: 1).outlineRows.firstMatch.staticTexts.firstMatch  // newest first: the dry run
        click(newest, until: text("Dry run: nothing was written to ADO. Calls marked \"not sent\" are what a sync would send."))
    }

    func testTicketDisclosureShowsCalls() {
        launch()
        openJob("Mobile bugs → ADO")
        tab("Sync History")
        click(row("#1"), until: text("Tickets"))
        let calls = app.disclosureTriangles.matching(NSPredicate(format: "label ENDSWITH 'ADO call' OR label ENDSWITH 'ADO calls'")).firstMatch
        if !calls.exists {  // tickets start folded
            let first = app.disclosureTriangles.firstMatch
            wait(first)
            first.click()
        }
        wait(calls)
        calls.click()
        wait(app.disclosureTriangles.matching(NSPredicate(format: "label == 'Details'")).firstMatch)
    }

    // MARK: Navigation

    func testPaletteJumpsToAPage() {
        launch()
        wait(text("Total Jobs"))
        app.typeKey("k", modifierFlags: .command)
        wait(field("palette.search"))
        field("palette.search").typeText("Settings\r")
        wait(button("Test Jira"))
    }

    func testPaletteOpensAJob() {
        launch()
        wait(text("Total Jobs"))
        app.typeKey("k", modifierFlags: .command)
        wait(field("palette.search"))
        field("palette.search").typeText("WEB\r")
        wait(button("Sync Now"))
        XCTAssertTrue(app.windows.firstMatch.title.hasPrefix("Web platform stories"))
    }

    func testSidebarPages() {
        launch()
        for (page, marker) in [("Sync Jobs", "Mobile bugs → ADO"), ("Logs", "All jobs"), ("Mappings", "Work item types"),
                               ("Analytics", "Coming soon"), ("Settings", "Test Jira"), ("Dashboard", "Total Jobs")] {
            sidebar(page)
            wait(app.descendants(matching: .any).matching(NSPredicate(format: "value == %@ OR label == %@ OR title == %@", marker, marker, marker)).firstMatch)
        }
    }

    // MARK: Logs, mappings, settings

    func testLogsFilterAndDelete() {
        launch()
        sidebar("Logs")
        let table = app.outlines.element(boundBy: 1)
        wait(row("#1"))
        let before = table.outlineRows.count
        XCTAssertGreaterThan(before, 1)
        table.outlineRows.firstMatch.buttons["Delete"].click()
        XCTAssertEqual(table.outlineRows.count, before - 1)
    }

    func testMappingsValidatesAndSaves() {
        launch()
        sidebar("Mappings")
        wait(button("Add Priority"))
        button("Add User").click()
        wait(text("Each shared user needs a Jira user and an ADO email."))
        XCTAssertFalse(button("Save").isEnabled)
        button("Revert").click()
        XCTAssertTrue(button("Save").isEnabled)
        button("Save").click()
        wait(text("Mappings saved; the next sync uses them"))
    }

    func testSettingsSaveAndTestJira() {
        launch()
        sidebar("Settings")
        type("settings.jiraURL", "https://site.test/", replacing: true)
        button("Save").click()
        wait(text("Settings saved"))
        button("Test Jira").click()
        wait(text("Jira: Jira API token is empty"))
    }

    func testThemeAndAppIcon() {
        launch()
        sidebar("Settings")
        let dark = field("settings.theme").radioButtons["Dark"].firstMatch
        wait(dark)
        dark.click()
        XCTAssertEqual(dark.value as? Int, 1, "a radio button's value is its selection")
        button("Lane change").click()
        XCTAssertTrue(button("Lane change").isSelected)
        XCTAssertFalse(button("Bridge").isSelected)
    }

    // MARK: Launch performance

    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let a = XCUIApplication()
            a.launchArguments = ["-ui-testing", "-signed-in"]
            a.launch()
            a.terminate()
        }
    }
}
