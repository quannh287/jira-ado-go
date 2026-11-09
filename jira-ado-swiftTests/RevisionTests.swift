import Foundation
import Testing

@testable import JirAdo

@Suite struct RevisionTests {
    private func run(_ id: Int, _ started: Date, _ duration: TimeInterval, _ kind: RunKind, _ adoID: Int, revs: [Int]) -> Run {
        let calls = revs.map { APICall(method: "PATCH", url: "/wit/workitems/\(adoID)", status: 200, response: #"{"id":\#(adoID),"rev":\#($0)}"#) }
        return Run(id: id, started: started, duration: duration, kind: kind, tickets: [Ticket(adoID: adoID, calls: calls)])
    }

    @Test func answeredRevisionsAreSyncTheRestManual() {
        let revs = (1...4).map { Revision(id: $0, rev: $0, at: t0.addingTimeInterval(Double($0) * 600)) }
        let out = attribute(revs, runs: [run(1, t0.addingTimeInterval(600), 5, .sync, 42, revs: [1, 3])], workItem: 42)
        #expect(out.map(\.source) == [.sync, .manual, .sync, .manual])
    }

    @Test func aRevisionInsideTheRunWindowIsOnlyLikely() {
        // A comment write answers with the comment, so its revision is never named; the window places it.
        let revs = [Revision(id: 2, rev: 2, at: t0.addingTimeInterval(3)), Revision(id: 9, rev: 9, at: t0.addingTimeInterval(9_999))]
        let out = attribute(revs, runs: [run(1, t0, 4, .sync, 42, revs: [1])], workItem: 42)
        #expect(out.map(\.source) == [.likelySync, .manual])
    }

    @Test func dryRunsAndOtherItemsNeverClaimARevision() {
        let revs = [Revision(id: 1, rev: 1, at: t0.addingTimeInterval(1))]
        #expect(attribute(revs, runs: [run(1, t0, 4, .dryRun, 42, revs: [1])], workItem: 42).first?.source == .manual)
        #expect(attribute(revs, runs: [run(1, t0, 4, .sync, 99, revs: [1])], workItem: 42).first?.source == .manual)
    }

    @Test(arguments: [("32602", 32602), ("https://dev.azure.com/o/P/_workitems/edit/32602", 32602), ("#7", 7),
                      ("", nil), ("abc", nil), ("0", nil)])
    func workItemIDAcceptsIDsAndURLs(input: String, want: Int?) {
        #expect(workItemID(input) == want)
    }
}
