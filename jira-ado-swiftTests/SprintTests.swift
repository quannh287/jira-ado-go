import Foundation
import Testing
@testable import JirAdo

/// An ADO holding a fixed set of work items, so every plan is checked against real field values.
final class FakeSprintADO: SprintAPI {
    var iterations: [Iteration] = []
    var items: [Int: JSONObject] = [:]
    var created: [[PatchOp]] = []
    var updated: [(Int, [PatchOp])] = []
    var failIDs: Set<Int> = []

    func wiql(_ query: String) async throws -> [Int] { items.keys.sorted() }

    func batch(_ ids: [Int], fields: [String]) async throws -> [JSONObject] {
        ids.compactMap { id in items[id].map { ["id": id, "fields": $0] } }
    }

    func iterations(under base: String) async throws -> [Iteration] { iterations }

    func create(type: String, ops: [PatchOp]) async throws -> Int {
        created.append(ops)
        return 900 + created.count
    }

    func update(_ id: Int, ops: [PatchOp]) async throws {
        if failIDs.contains(id) { throw Failure("ADO 500") }
        updated.append((id, ops))
    }

    func parentRelation(_ parentID: Int) -> PatchOp {
        PatchOp(op: "add", path: "/relations/-", value: ["rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://x/_apis/wit/workItems/\(parentID)"])
    }
}

private let monday = parseDay("2026-11-09")!  // the sprint under test runs Mon 9 – Fri 13 Nov 2026
private let sprintPath = #"Tickets\Weekly Sprint\Sprint 87"#
private let oldPath = #"Tickets\Weekly Sprint\Sprint 86"#
private let area = #"Tickets\KPL\KAI"#

private func iteration(_ n: Int, _ start: String, _ finish: String) -> Iteration {
    Iteration(path: #"Tickets\Weekly Sprint\Sprint \#(n)"#, start: parseDay(start)!, finish: parseDay(finish)!)
}

private let allIterations = [
    iteration(85, "2026-10-26", "2026-10-30"),
    iteration(86, "2026-11-02", "2026-11-06"),
    iteration(87, "2026-11-09", "2026-11-13"),
    iteration(88, "2026-11-16", "2026-11-20"),
]

private func config(_ effort: Int = 50) -> SprintConfig {
    SprintConfig(adoEmail: "me@x.com", workweekHours: 40,
                 projects: [SprintProject(name: "KAI-GO", adoProject: "Tickets", areaPath: area,
                                          iterationBase: #"Tickets\Weekly Sprint"#, effortPct: effort)],
                 activities: [ActivityGroup(project: "KAI-GO", parentID: 500, items: [
                     ActivityItem(title: "{sprint_name} | Sprint Planning", priority: 1, parity: .odd),
                     ActivityItem(title: "{sprint_name} | Sprint Retrospective", priority: 4, parity: .even),
                     ActivityItem(title: "Sprint {sprint_number} weekly demo", priority: 2, parity: .every),
                 ])])
}

private func fields(_ title: String, type: String = typeTask, state: String = "To Do", estimate: Double = 0,
                    priority: Int = 0, due: String = "", parent: Int = 0, iteration: String = sprintPath) -> JSONObject {
    [Field.title: title, Field.workItemType: type, Field.state: state, Field.originalEstimate: estimate,
     Field.priority: priority, Field.dueDate: due.isEmpty ? "" : due + "T00:00:00Z", Field.parent: parent,
     Field.iteration: iteration, Field.area: area]
}

@MainActor
private func tracker(_ ado: FakeSprintADO, _ c: SprintConfig = config(), at t: Date = monday) -> SprintTracker {
    let s = SprintTracker(config: c, org: "org", pat: "pat", now: { t })
    s.client = { _ in ado }
    return s
}

@Suite("Sprint resolution")
struct SprintResolutionTests {
    @Test func picksTheSprintHoldingToday() {
        let friday = parseDay("2026-11-13")!
        #expect(SprintTracker.current(allIterations, at: friday)?.number == 87)
    }

    @Test func weekendRunsPlanTheWeekAhead() {
        let saturday = parseDay("2026-11-14")!
        #expect(SprintTracker.current(allIterations, at: saturday)?.number == 88)
    }

    @Test func sprintNumberAndDaysComeFromTheNode() {
        let s = iteration(87, "2026-11-09", "2026-11-13")
        #expect(s.number == 87)
        #expect(s.days.map(dayString) == ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13"])
    }
}

@Suite("Sprint board")
@MainActor
struct SprintBoardTests {
    private func loaded(_ extra: [Int: JSONObject] = [:]) async throws -> (SprintTracker, SprintBoard, FakeSprintADO) {
        let ado = FakeSprintADO()
        ado.iterations = allIterations
        ado.items = [
            10: fields("PBI one", type: typePBI, state: "In Progress"),
            11: fields("[P1-BE] api", estimate: 3, parent: 10),
            12: fields("[P2-FE] screen", estimate: 2, parent: 10),
            13: fields("done work", state: "Done", estimate: 4),
        ].merging(extra) { _, b in b }
        let t = tracker(ado)
        return (t, try await t.load(), ado)
    }

    @Test func splitsTheSprintFromWhatSitsOutsideIt() async throws {
        let (_, b, _) = try await loaded([20: fields("carry-over", estimate: 2, iteration: oldPath)])
        #expect(b.sprint.number == 87)
        #expect(b.tasks.map(\.id).sorted() == [10, 11, 12, 13])
        #expect(b.outside.map(\.id) == [20])
    }

    @Test func committedHoursSumTasksOnlyAndCountDoneWork() async throws {
        let (_, b, _) = try await loaded([14: fields("PBI with hours", type: typePBI, estimate: 9)])
        // 3 + 2 + 4; the PBI's 9h is a container's and never counts.
        #expect(committedHours(b.tasks) == 9)
    }

    @Test func containerHoursAreOfferedForClearing() async throws {
        let (t, b, _) = try await loaded([14: fields("PBI with hours", type: typePBI, estimate: 9)])
        let plan = t.clearContainerHours(b)
        #expect(plan.map(\.workItem) == [14])
        #expect(plan[0].ops.first?.value is NSNull)
    }

    @Test func removedItemsAndOtherAreasAreDropped() async throws {
        var other = fields("someone else's area", estimate: 5)
        other[Field.area] = #"Tickets\GAL\GCC"#
        let (_, b, _) = try await loaded([21: fields("gone", state: "Removed"), 22: other])
        #expect(!b.tasks.contains { $0.id == 21 || $0.id == 22 })
    }
}

@Suite("Carry-over and moves")
@MainActor
struct SprintMoveTests {
    private func board(_ items: [Int: JSONObject]) async throws -> (SprintTracker, SprintBoard) {
        let ado = FakeSprintADO()
        ado.iterations = allIterations
        ado.items = items
        let t = tracker(ado)
        return (t, try await t.load())
    }

    @Test func movesOnlyWorkLeftInAFinishedSprint() async throws {
        let (t, b) = try await board([
            30: fields("stale", estimate: 2, iteration: oldPath),
            31: fields("deliberately later", estimate: 2, iteration: #"Tickets\Weekly Sprint\Sprint 88"#),
        ])
        let plan = t.carryOverPlan(b)
        #expect(plan.map(\.workItem) == [30])
        #expect(plan[0].ops[0].value as? String == sprintPath)
    }

    @Test func movingAContainerTakesItsTasks() async throws {
        let (t, b) = try await board([
            40: fields("PBI outside", type: typePBI, iteration: oldPath),
            41: fields("child a", estimate: 1, parent: 40, iteration: oldPath),
            42: fields("child b", estimate: 1, parent: 40, iteration: oldPath),
            43: fields("unrelated", estimate: 1, iteration: oldPath),
        ])
        #expect(t.movePlan([40], to: sprintPath, b).map(\.workItem).compactMap { $0 }.sorted() == [40, 41, 42])
    }

    @Test func anItemAlreadyThereIsNotRewritten() async throws {
        let (t, b) = try await board([50: fields("already here", estimate: 1)])
        #expect(t.movePlan([50], to: sprintPath, b).isEmpty)
    }

    @Test func pushingOutTargetsTheNextSprint() async throws {
        let (_, b) = try await board([60: fields("in sprint", estimate: 1)])
        #expect(b.next?.number == 88)
    }
}

@Suite("Activity tasks")
@MainActor
struct SprintActivityTests {
    private func plan(_ items: [Int: JSONObject], at t: Date = monday) async throws -> [SprintChange] {
        let ado = FakeSprintADO()
        ado.iterations = allIterations
        ado.items = items
        let tr = tracker(ado, config(), at: t)
        return try await tr.activityPlan(tr.load())
    }

    @Test func parityKeepsPlanningAndRetroInAlternateWeeks() async throws {
        // Sprint 87 is odd: planning and the weekly demo, never the retrospective.
        let titles = try await plan([:]).map(\.title)
        #expect(titles.contains("Sprint 87 | Sprint Planning"))
        #expect(titles.contains("Sprint 87 weekly demo"))
        #expect(!titles.contains { $0.contains("Retrospective") })
    }

    @Test func evenSprintsGetTheRetrospective() async throws {
        let titles = try await plan([:], at: parseDay("2026-11-16")!).map(\.title)
        #expect(titles.contains("Sprint 88 | Sprint Retrospective"))
        #expect(!titles.contains { $0.contains("Planning") })
    }

    @Test func anExistingCeremonyIsNotCreatedTwice() async throws {
        let titles = try await plan([70: fields("Sprint 87 | Sprint Planning", estimate: 1)]).map(\.title)
        #expect(!titles.contains("Sprint 87 | Sprint Planning"))
    }

    @Test func aCeremonyCarriesItsHoursDayAndParent() async throws {
        let c = try await plan([:]).first { $0.title.contains("Planning") }
        let ops = Dictionary(c!.ops.map { ($0.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(ops["/fields/\(Field.originalEstimate)"] as? Int == 1)
        #expect(ops["/fields/\(Field.dueDate)"] as? String == "2026-11-09")  // P1 = Monday
        #expect(ops["/fields/\(Field.iteration)"] as? String == sprintPath)
        #expect(c!.ops.contains { $0.path == "/relations/-" })
    }
}

@Suite("Weekly schedule")
@MainActor
struct SprintScheduleTests {
    private func plan(_ items: [Int: JSONObject], effort: Int = 50) async throws -> [SprintChange] {
        let ado = FakeSprintADO()
        ado.iterations = allIterations
        ado.items = items
        let t = tracker(ado, config(effort))
        return try await t.schedulePlan(t.load())
    }

    private func due(_ c: SprintChange) -> String { c.ops.first { $0.path == "/fields/\(Field.dueDate)" }?.value as? String ?? "" }
    private func priority(_ c: SprintChange) -> Int { c.ops.first { $0.path == "/fields/\(Field.priority)" }?.value as? Int ?? 0 }

    @Test func planningStaysOnMondayWhateverTheLoad() async throws {
        let p = try await plan([
            80: fields("Sprint 87 | Sprint Planning", estimate: 1),
            81: fields("heavy", estimate: 8),
        ])
        let planning = p.first { $0.title.contains("Planning") }
        #expect(due(planning!) == "2026-11-09")
        #expect(priority(planning!) == 1)
    }

    @Test func workInProgressGoesToMonday() async throws {
        let p = try await plan([82: fields("underway", state: "In Progress", estimate: 2)])
        #expect(due(p[0]) == "2026-11-09")
    }

    @Test func aDayAlreadyArrangedIsLeftAlone() async throws {
        let p = try await plan([83: fields("already scheduled", estimate: 2, priority: 3, due: "2026-11-12")])
        #expect(p.isEmpty)
    }

    @Test func tasksSpreadOverTheWeekOnceADayIsFull() async throws {
        // 20h budget = 4h a day, plus the 1h the user tolerates.
        let p = try await plan([
            84: fields("a", estimate: 4), 85: fields("b", estimate: 4), 86: fields("c", estimate: 4),
        ])
        #expect(Set(p.map(due)).count == 3)
        #expect(priority(p.first { $0.title.contains("#84") }!) == 1)
    }

    @Test func doneAndContainerItemsAreNotScheduled() async throws {
        let p = try await plan([87: fields("finished", state: "Done", estimate: 2), 88: fields("PBI", type: typePBI)])
        #expect(p.isEmpty)
    }
}

@Suite("Ad-hoc edits")
@MainActor
struct SprintAdhocTests {
    private func board() async throws -> (SprintTracker, SprintBoard) {
        let ado = FakeSprintADO()
        ado.iterations = allIterations
        ado.items = [90: fields("PBI", type: typePBI), 91: fields("task", estimate: 2, priority: 1, due: "2026-11-09", parent: 90)]
        let t = tracker(ado)
        return (t, try await t.load())
    }

    @Test func changingTheDayMovesThePriorityWithIt() async throws {
        let (t, b) = try await board()
        let c = t.fieldsChange(b.task(91)!, estimate: 3, offset: 3, b)
        let ops = Dictionary(c!.ops.map { ($0.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(ops["/fields/\(Field.priority)"] as? Int == 3)  // Thursday
        #expect(ops["/fields/\(Field.dueDate)"] as? String == "2026-11-12")
        #expect(ops["/fields/\(Field.originalEstimate)"] as? Double == 3)
    }

    @Test func anUnchangedTaskProducesNoWrite() async throws {
        let (t, b) = try await board()
        #expect(t.fieldsChange(b.task(91)!, estimate: 2, offset: 0, b) == nil)
    }

    @Test func aNewTaskIsBornWithEveryPlanningField() async throws {
        let (t, b) = try await board()
        let c = t.newTaskChange(project: config().projects[0], parent: 90, title: "hotfix", estimate: 1.5, offset: 4, b)
        let ops = Dictionary(c.ops.map { ($0.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(ops["/fields/\(Field.dueDate)"] as? String == "2026-11-13")
        #expect(ops["/fields/\(Field.priority)"] as? Int == 4)
        #expect(ops["/fields/\(Field.iteration)"] as? String == sprintPath)
        #expect(c.ops.contains { $0.path == "/relations/-" })
    }

    @Test func oneFailedWriteDoesNotStopTheRest() async throws {
        let ado = FakeSprintADO()
        ado.iterations = allIterations
        ado.items = [92: fields("a", estimate: 1), 93: fields("b", estimate: 1)]
        ado.failIDs = [92]
        let t = tracker(ado)
        let b = try await t.load()
        let errors = await t.apply(t.movePlan([92, 93], to: oldPath, b))
        #expect(errors.count == 1)
        #expect(ado.updated.map(\.0) == [93])
    }
}

@Suite("Snapshots and review")
@MainActor
struct SprintReviewTests {
    private func day(_ s: String) -> Date { parseDay(s)! }

    private func store(_ days: [(String, [SprintTask])]) -> Store {
        let st = Store()
        for (d, tasks) in days { st.saveSnapshot(sprint: sprintPath, day: d, tasks: tasks) }
        return st
    }

    private func task(_ id: Int, estimate: Double = 2, state: String = "To Do", due: String = "2026-11-10") -> SprintTask {
        SprintTask(id: id, project: "KAI-GO", title: "t\(id)", type: typeTask, state: state, estimate: estimate, due: due)
    }

    @Test func aSecondSnapshotOnTheSameDayReplacesTheFirst() {
        let st = store([("2026-11-09", [task(1)]), ("2026-11-09", [task(1, estimate: 5)])])
        #expect(st.snapshots(sprint: sprintPath).count == 1)
        #expect(st.snapshots(sprint: sprintPath)[0].tasks[0].estimate == 5)
    }

    @Test func remainingAndDoneHoursComeFromTheDay() {
        let d = SprintDay(day: day("2026-11-10"), tasks: [task(1), task(2, state: "Done")])
        #expect(d.remaining == 2)
        #expect(d.doneHours == 2)
    }

    @Test func closingOnTheDuedayIsOnTimeAndAfterItIsLate() {
        let days = store([
            ("2026-11-09", [task(1), task(2)]),
            ("2026-11-10", [task(1, state: "Done"), task(2)]),
            ("2026-11-11", [task(1, state: "Done"), task(2, state: "Done")]),
        ]).snapshots(sprint: sprintPath)
        let v = Dictionary(review(days).map { ($0.task.id, $0.verdict) }, uniquingKeysWith: { a, _ in a })
        #expect(v[1] == .onTime)
        #expect(v[2] == .late)
    }

    @Test func workPulledInMidWeekIsUnplannedAndNeverJoinsTheBaseline() {
        let days = store([
            ("2026-11-09", [task(1)]),
            ("2026-11-11", [task(1), task(9)]),
        ]).snapshots(sprint: sprintPath)
        let v = Dictionary(review(days).map { ($0.task.id, $0.verdict) }, uniquingKeysWith: { a, _ in a })
        #expect(v[9] == .unplanned)
        #expect(days[0].tasks.map(\.id) == [1])
    }

    @Test func aChangedEstimateAndAVanishedTaskAreBothReported() {
        let days = store([
            ("2026-11-09", [task(1), task(2)]),
            ("2026-11-11", [task(1, estimate: 6)]),
        ]).snapshots(sprint: sprintPath)
        let v = Dictionary(review(days).map { ($0.task.id, $0.verdict) }, uniquingKeysWith: { a, _ in a })
        #expect(v[1] == .reestimated)
        #expect(v[2] == .movedOut)
    }
}

@Suite("Sprint config")
struct SprintConfigTests {
    @Test func budgetSplitsTheWorkWeekByEffort() {
        #expect(SprintConfig.seed.projects.first { $0.name == "KAI-GO" }?.budget(40) == 20)
        #expect(SprintConfig.seed.budget == 40)
    }

    @Test func aConfigWithoutAnEmailOrProjectIsNotUsable() {
        #expect(!SprintConfig().configured)
        #expect(SprintConfig.seed.configured)
    }

    @Test func theSeedSurvivesARoundTripThroughSettings() throws {
        let store = Store()
        store.setSprintConfig(.seed)
        #expect(store.sprintConfig == SprintConfig.seed)
    }

    @Test func theWeekdayGridMapsBothWays() {
        #expect((1...4).map(priorityOffset) == [0, 2, 3, 4])
        #expect((0..<5).map(offsetPriority) == [1, 2, 2, 3, 4])
    }
}
