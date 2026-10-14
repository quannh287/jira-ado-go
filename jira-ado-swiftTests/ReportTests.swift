import Foundation
import Testing
@testable import JirAdo

@Test func syncedSummary() {
    let calls = [
        APICall(method: "POST", url: "https://dev.azure.com/o/p/_apis/wit/wiql?api-version=7.1", request: #"{"query":"SELECT"}"#, status: 200),
        APICall(method: "POST", url: "https://dev.azure.com/o/p/_apis/wit/workitems/$Task?api-version=7.1", request: #"""
            [{"op":"add","path":"/fields/System.Title","value":"SE-1 - 10 - Fix login"},
             {"op":"add","path":"/fields/System.State","value":"To Do"},
             {"op":"add","path":"/fields/System.Description","value":"<p><strong>a &amp; b</strong></p>"},
             {"op":"add","path":"/relations/-","value":{"rel":"System.LinkTypes.Hierarchy-Reverse","url":"x"}}]
            """#, status: 200),
        APICall(method: "PATCH", url: "https://dev.azure.com/o/p/_apis/wit/workitems/5?api-version=7.1",
                request: #"[{"op":"add","path":"/fields/System.State","value":"In Progress"},{"op":"add","path":"/relations/-","value":{"rel":"AttachedFile","url":"y"}}]"#, status: 200),
        APICall(method: "PATCH", url: "https://dev.azure.com/o/p/_apis/wit/workitems/5?api-version=7.1",
                request: #"[{"op":"add","path":"/fields/System.State","value":"Done"}]"#, status: 400),
        APICall(method: "POST", url: "https://dev.azure.com/o/p/_apis/wit/workItems/5/comments?api-version=7.1-preview.4", request: #"{"text":"hi"}"#, status: 200),
    ]
    let (fields, notes) = synced(calls)
    #expect(fields == [SyncedField(name: "Title", value: "SE-1 - 10 - Fix login"), SyncedField(name: "State", value: "In Progress"),
                       SyncedField(name: "Description", value: "a & b")])
    #expect(notes.count == 3)  // parent, attachment, comment
    #expect(shortURL(calls[2].url) == "/wit/workitems/5")
}

@Test func referenceLinks() {
    #expect(issueURL("https://keppel-ltd.atlassian.net/", "CAT-284")?.absoluteString == "https://keppel-ltd.atlassian.net/browse/CAT-284")
    #expect(workItemURL("ats-technology", "My Project", 32143)?.absoluteString == "https://dev.azure.com/ats-technology/My%20Project/_workitems/edit/32143")
    #expect(issueURL("", "X-1") == nil && workItemURL("o", "p", 0) == nil)
}

@Test func groups() {
    let tk = { (key: String, parent: String) in Ticket(key: key, parentKey: parent) }
    let tickets = [tk("CAT-341", "CAT-284"), tk("CAT-284", ""), tk("CAT-342", "CAT-284"), tk("CAT-400", ""), tk("CAT-501", "CAT-500"), tk("CAT-502", "CAT-500")]
    let g = groupTickets(tickets)
    #expect(g == [TicketGroup(parent: 1, parentKey: "CAT-284", children: [0, 2]), TicketGroup(parent: 3, parentKey: "CAT-400"),
                  TicketGroup(parent: nil, parentKey: "CAT-500", children: [4, 5])])
}

@Test func syncedSkipsFailedAndUnparsableCalls() {
    let calls = [APICall(method: "PATCH", url: "x/workitems/1", request: "not json", status: 200),
                 APICall(method: "PATCH", url: "x/workitems/1", request: #"[{"op":"add","path":"/fields/System.Title","value":"t"}]"#, status: 200, error: "timeout"),
                 APICall(method: "PATCH", url: "x/workItems/1/comments/3", request: "{}", status: 200)]
    let (fields, notes) = synced(calls)
    #expect(fields.isEmpty && notes == ["1 comment updated"])
}

@Test func oneLineStripsHTMLAndTruncates() {
    #expect(oneLine("<p>a &amp; <b>b</b></p>\n<p>c</p>") == "a & b c")
    #expect(oneLine(2.0) == "2")
    #expect(oneLine(String(repeating: "x", count: 100)) == String(repeating: "x", count: 90) + "…")
}

@Test func shortURLs() {
    #expect(shortURL("https://dev.azure.com/o/p/_apis/wit/wiql?api-version=7.1") == "/wit/wiql")
    #expect(shortURL("https://dev.azure.com/o/p/_apis/wit/x?fileName=a&api-version=7.1") == "/wit/x?fileName=a")
    #expect(shortURL("/wit/workitems/1 (remove attachments)") == "/wit/workitems/1 (remove attachments)")
}

@Test func formatting() {
    #expect(fmtDuration(0.84) == "0.8s" && fmtDuration(12) == "12s" && fmtDuration(125.06) == "2m5.1s")
    #expect(ago(t0, t0.addingTimeInterval(30)) == "just now")
    #expect(ago(t0, t0.addingTimeInterval(300)) == "5m ago")
    #expect(ago(t0, t0.addingTimeInterval(7200)) == "2h ago")
    #expect(ago(t0, t0.addingTimeInterval(3 * 86400)) == "3d ago")
    #expect(plural(1, "call") == "1 call" && plural(2, "call") == "2 calls")
    #expect(fmtEvery(3600) == "1 hour" && fmtEvery(600) == "10 minutes")
    #expect(progressText(SyncProgress(run: Run())) == "Searching Jira…")
    #expect(progressText(SyncProgress(run: Run(), done: 3, total: 9)) == "3 of 9 issues")
    #expect(kindLabel(.dryRun) == "dry run" && kindLabel(.retry) == "retry" && kindLabel(.sync) == "")
    let r = Run(tickets: [Ticket(outcome: .created), Ticket(outcome: .failed)])
    #expect(fmtRunCounts(r) == "1 created · 0 updated · 0 skipped · 1 failed")
    #expect(fmtRunSummary(r) == "1 created, 0 updated, 0 skipped, 1 failed")
}

@Test func syncTypeLabels() {
    var j = Job(type: .scheduler)
    j.filters.everyMinutes = 180
    #expect(syncTypeLabel(j) == "Scheduler · every 3 hours")
    #expect(syncTypeLabel(Job(type: .manual)) == "Manual")
}

@Test func notificationIDs() {
    #expect(notificationID(3, 41) == "run/3/41")
    #expect(parseNotificationID("run/3/41")! == (3, 41))
    for bad in ["test", "run/3", "run/x/1", "job/3/41"] { #expect(parseNotificationID(bad) == nil) }
}
