import Foundation
import Testing
@testable import jira_ado

/// Answers every request from `handler`, recording what was asked.
nonisolated final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String, url: String, body: String, headers: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: @Sendable (Recorded) -> (Int, String) = { _ in (200, "{}") }
    nonisolated(unsafe) private static var log: [Recorded] = []

    static func respond(_ h: @escaping @Sendable (Recorded) -> (Int, String)) { lock.withLock { handler = h; log = [] } }
    static var requests: [Recorded] { lock.withLock { log } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let s = request.httpBodyStream {  // URLSession hands bodies over as a stream
            s.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable, case let n = s.read(&buf, maxLength: buf.count), n > 0 { body.append(buf, count: n) }
            s.close()
        }
        let rec = Recorded(method: request.httpMethod ?? "", url: request.url?.absoluteString ?? "",
                           body: String(decoding: body, as: UTF8.self), headers: request.allHTTPHeaderFields ?? [:])
        let (status, text) = Self.lock.withLock {
            Self.log.append(rec)
            return Self.handler(rec)
        }
        if status == 0 {  // a dropped connection
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Counts calls from URLSession's thread.
nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

/// Network tests share the stubbed session, so they run one at a time.
@Suite(.serialized)
struct NetworkTests {
    init() {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        HTTPClient.session = URLSession(configuration: c)
        HTTPClient.retryDelay = 0
        ADOClient.host = "https://ado.test"
    }

    // MARK: HTTP retries

    @Test func retriesTransientFailuresThenSucceeds() async {
        let c = Counter()
        StubProtocol.respond { _ in
            let n = c.next()
            return n == 1 ? (503, "busy") : n == 2 ? (429, "slow down") : (200, "ok")
        }
        let (resp, err) = await HTTPClient(base: "https://x.test/", auth: "Basic a").send("GET", "/path")
        #expect(err == nil && resp.status == 200 && resp.retries == 2 && String(decoding: resp.body, as: UTF8.self) == "ok")
        #expect(StubProtocol.requests.map(\.url) == Array(repeating: "https://x.test/path", count: 3))
        #expect(StubProtocol.requests[0].headers["Authorization"] == "Basic a")
    }

    @Test func retriesDroppedConnections() async {
        let c = Counter()
        StubProtocol.respond { _ in
            let n = c.next()
            return n == 1 ? (0, "") : (200, "ok")
        }
        let (resp, err) = await HTTPClient(base: "https://x.test", auth: "").send("GET", "/p")
        #expect(err == nil && resp.retries == 1)
    }

    @Test func neverRetriesClientErrors() async {
        StubProtocol.respond { _ in (404, "missing") }
        let (resp, err) = await HTTPClient(base: "https://x.test", auth: "").send("GET", "/p")
        #expect((err as? HTTPStatusError)?.status == 404 && resp.retries == 0 && StubProtocol.requests.count == 1)
    }

    @Test func givesUpAfterThreeRetries() async {
        StubProtocol.respond { _ in (500, "down") }
        let (resp, err) = await HTTPClient(base: "https://x.test", auth: "").send("POST", "https://abs.test/q", contentType: "application/json", body: Data("{}".utf8))
        #expect((err as? HTTPStatusError)?.status == 500 && resp.retries == 3 && StubProtocol.requests.count == 4)
        #expect(StubProtocol.requests[0].url == "https://abs.test/q", "absolute URLs ignore the base")
        #expect(StubProtocol.requests[0].body == "{}" && StubProtocol.requests[0].headers["Content-Type"] == "application/json")
    }

    // MARK: Jira

    private var jira: JiraClient { JiraClient(baseURL: "https://site.test/", email: "me@x.io", token: "tok") }

    @Test func jiraSearchPagesWithToken() async throws {
        StubProtocol.respond { r in
            r.body.contains("nextPageToken") ? (200, #"{"issues":[{"id":"2","key":"SE-2","fields":{"summary":"two"}}],"isLast":true}"#)
                : (200, #"{"issues":[{"id":"1","key":"SE-1","fields":{"summary":"one","customfield_1":[{"state":"active"}]}}],"nextPageToken":"t2"}"#)
        }
        let issues = try await jira.search("project = \"SE\"", fields: ["id"])
        #expect(issues.map(\.key) == ["SE-1", "SE-2"] && issues[0].summary == "one" && issues[0].inActiveSprint("customfield_1"))
        let req = StubProtocol.requests[0]
        #expect(req.method == "POST" && req.url == "https://site.test/rest/api/3/search/jql")
        #expect(req.headers["Authorization"] == basicAuth("me@x.io", "tok"))
        #expect(StubProtocol.requests[1].body.contains(#""nextPageToken":"t2""#))
    }

    @Test func jiraSearchErrorNamesTheQuery() async {
        StubProtocol.respond { _ in (400, "bad jql") }
        await #expect(throws: (any Error).self) { try await jira.search("broken", fields: []) }
        do { _ = try await jira.search("broken", fields: []) } catch { #expect(describe(error).hasPrefix(#"jira search "broken": "#)) }
    }

    @Test func jiraCommentsPageByStartAt() async throws {
        StubProtocol.respond { r in
            r.url.contains("startAt=0") ? (200, #"{"comments":[{"id":"c1","updated":"u1","author":{"displayName":"Ana"}}],"total":2}"#)
                : (200, #"{"comments":[{"id":"c2","updated":"u2"}],"total":2}"#)
        }
        let cs = try await jira.comments("SE 1")
        #expect(cs.map(\.id) == ["c1", "c2"] && cs[0].author?.displayName == "Ana" && cs[1].author == nil)
        #expect(StubProtocol.requests[0].url.contains("/issue/SE%201/comment?startAt=0"))
    }

    @Test func jiraSprintFieldTimeZoneAndCatalog() async throws {
        StubProtocol.respond { r in
            switch true {
            case r.url.hasSuffix("/field"): (200, #"[{"id":"summary","schema":{}},{"id":"customfield_10020","schema":{"custom":"com.pyxis.greenhopper.jira:gh-sprint"}}]"#)
            case r.url.hasSuffix("/myself"): (200, #"{"displayName":"Me","timeZone":"Asia/Singapore"}"#)
            case r.url.hasSuffix("/priority"): (200, #"[{"name":"High"},{"name":"Low"}]"#)
            default: (200, #"[{"name":"Bug","statuses":[{"name":"To Do"},{"name":"Done"}]},{"name":"Task","statuses":[{"name":"To Do"}]}]"#)
            }
        }
        #expect(try await jira.sprintField() == "customfield_10020")
        #expect(try await jira.timeZone().identifier == "Asia/Singapore")
        #expect(try await jira.myself() == "Me")
        #expect(try await jira.priorities() == ["High", "Low"])
        let (types, statuses) = try await jira.projectStatuses("SE")
        #expect(types == ["Bug", "Task"] && statuses == ["To Do", "Done", "To Do"])
    }

    @Test func jiraIssueFields() {
        let i = JiraIssue(id: "1", key: "SE-1", fields: [
            "issuetype": ["name": "Sub-task", "subtask": true], "parent": ["id": "9", "key": "SE-9"],
            "priority": ["name": "High"], "status": ["name": "Done"], "aggregatetimespent": 5400,
            "subtasks": [["id": "2", "key": "SE-2"]], "attachment": [["filename": "a.png", "content": "https://x/a"]],
            "assignee": ["emailAddress": "a@x.io", "displayName": "A"], "reporter": NSNull(),
        ])
        #expect(i.issueType == "Sub-task" && i.isSubtaskType && i.parent?.key == "SE-9" && i.priority == "High" && i.status == "Done")
        #expect(i.timeSpent == 5400 && i.timeEstimate == 0 && i.subtasks.map(\.id) == ["2"] && i.attachments.first?.filename == "a.png")
        #expect(i.assignee?.email == "a@x.io" && i.reporter == nil && !i.inActiveSprint("customfield_1"))
    }

    // MARK: ADO

    @Test func adoFindEscapesWIQLAndLogsCalls() async throws {
        StubProtocol.respond { _ in (200, #"{"workItems":[{"id":42}]}"#) }
        let a = ADOClient(org: "my org", project: "kai", pat: "pat")
        var calls: [APICall] = []
        a.onCall = { calls.append($0) }
        #expect(try await a.find(field: "Custom.JiraID", value: "O'Brien - 1") == 42)
        let req = StubProtocol.requests[0]
        #expect(req.url.hasPrefix("https://ado.test/my%20org/kai/_apis/wit/wiql"))
        #expect(req.body.contains("[Custom.JiraID] = 'O''Brien - 1'"))
        #expect(req.headers["Authorization"] == patAuth("pat"))
        #expect(calls.count == 1 && calls[0].status == 200 && calls[0].method == "POST" && calls[0].request.contains("SELECT"))
    }

    @Test func adoFailedCallKeepsResponseInReport() async {
        StubProtocol.respond { _ in (400, #"{"message":"TF401320"}"#) }
        let a = ADOClient(org: "o", project: "p", pat: "x")
        var calls: [APICall] = []
        a.onCall = { calls.append($0) }
        await #expect(throws: HTTPStatusError.self) { try await a.update(1, ops: [PatchOp(op: "add", path: "/fields/System.Title", value: "t")]) }
        #expect(calls.first?.status == 400 && calls.first?.response.contains("TF401320") == true && calls.first?.error.contains("HTTP 400") == true)
    }

    @Test func adoNodeExists() async throws {
        StubProtocol.respond { r in r.url.contains("/Missing") ? (404, "") : (200, "{}") }
        let a = ADOClient(org: "o", project: "Tickets", pat: "x")
        #expect(try await a.nodeExists(kind: "areas", path: #"Tickets\KPL\KAI"#))
        #expect(StubProtocol.requests.last?.url.contains("/classificationnodes/areas/KPL/KAI?$depth=0") == true)
        #expect(try await !a.nodeExists(kind: "iterations", path: #"Tickets\Missing"#))
        #expect(try await !a.nodeExists(kind: "areas", path: #"Other\KPL"#), "a path outside the project can't be used")
    }

    @Test func adoWorkItemAndCatalog() async throws {
        StubProtocol.respond { r in
            switch true {
            case r.url.contains("/states"): (200, #"{"value":[{"name":"New"},{"name":"Done"}]}"#)
            case r.url.contains("/workitemtypes"): (200, #"{"value":[{"name":"Bug"},{"name":"Old","isDisabled":true}]}"#)
            default: (200, #"{"fields":{"System.State":"New"},"relations":[{"rel":"AttachedFile","url":"u"}]}"#)
            }
        }
        let a = ADOClient(org: "o", project: "p", pat: "x")
        let w = try await a.get(7)
        #expect(w.fields["System.State"] as? String == "New" && w.relations.first?.rel == "AttachedFile")
        #expect(try await a.workItemTypes() == ["Bug"])
        #expect(try await a.states("Product Backlog Item") == ["New", "Done"])
        #expect(StubProtocol.requests.last?.url.contains("/workitemtypes/Product%20Backlog%20Item/states") == true)
    }

    @Test func adoCreateAttachAndComments() async throws {
        StubProtocol.respond { r in
            r.url.contains("/attachments") ? (200, #"{"url":"https://ado.test/att/1"}"#) : r.url.contains("/comments") ? (200, #"{"id":5}"#) : (200, #"{"id":77}"#)
        }
        let a = ADOClient(org: "o", project: "p", pat: "x")
        #expect(try await a.create(type: "Task", ops: [PatchOp(op: "add", path: "/fields/System.Title", value: "t"), a.parentRelation(3)]) == 77)
        let create = StubProtocol.requests[0]
        #expect(create.url.contains("/wit/workitems/$Task?") && create.headers["Content-Type"] == "application/json-patch+json")
        #expect(create.body.contains("https://ado.test/o/p/_apis/wit/workItems/3"))
        try await a.attach(77, name: "a b.png", data: Data("img".utf8))
        #expect(StubProtocol.requests[1].url.contains("fileName=a%20b.png") && StubProtocol.requests[1].body == "img")
        #expect(StubProtocol.requests[2].body.contains(#""rel" : "AttachedFile""#))
        #expect(try await a.addComment(77, html: "<p>x</p>") == 5)
        try await a.updateComment(77, commentID: 5, html: "<p>y</p>")
        #expect(StubProtocol.requests.last?.method == "PATCH" && StubProtocol.requests.last?.url.contains("/comments/5?api-version=7.1-preview.4") == true)
    }

    @Test func adoRemoveAttachmentsFromTheEnd() async throws {
        StubProtocol.respond { _ in (200, "{}") }
        let a = ADOClient(org: "o", project: "p", pat: "x")
        try await a.removeAttachments(1, [Relation(rel: "AttachedFile", url: ""), Relation(rel: "System.LinkTypes.Hierarchy-Reverse", url: ""), Relation(rel: "AttachedFile", url: "")])
        let ops = parseJSON(Data(StubProtocol.requests[0].body.utf8)) as? [JSONObject]
        #expect(ops?.compactMap { $0["path"] as? String } == ["/relations/2", "/relations/0"])
        try await a.removeAttachments(1, [])
        #expect(StubProtocol.requests.count == 1, "nothing to remove, nothing sent")
    }

    @Test func adoConnectionData() async throws {
        StubProtocol.respond { _ in (200, #"{"authenticatedUser":{"id":"abc","providerDisplayName":"Quan"}}"#) }
        #expect(try await ADOClient.connectionData(org: "o", pat: "x") == "Quan")
        StubProtocol.respond { _ in (200, #"{"authenticatedUser":{"id":"00000000-0000-0000-0000-000000000000"}}"#) }
        await #expect(throws: Failure.self) { try await ADOClient.connectionData(org: "o", pat: "x") }
        StubProtocol.respond { _ in (200, "<html>sign in</html>") }
        await #expect(throws: Failure.self) { try await ADOClient.connectionData(org: "o", pat: "x") }
    }

    @Test func syncerCatalogKeepsWhatLoaded() async {
        StubProtocol.respond { r in
            switch true {
            case r.url.contains("site.test") && r.url.hasSuffix("/priority"): (500, "down")
            case r.url.contains("site.test"): (200, #"[{"name":"Bug","statuses":[{"name":"QA"}]}]"#)
            case r.url.contains("/states"): (200, #"{"value":[{"name":"New"}]}"#)
            default: (200, #"{"value":[{"name":"Task"},{"name":"Bug"}]}"#)
            }
        }
        let conn = Connection(adoOrg: "o", pat: "p", jiraURL: "https://site.test", jiraEmail: "e", jiraToken: "t")
        let (cat, err) = await Syncer(state: Store()).catalog(conn, jiraProjects: ["SE"], adoProjects: ["kai"])
        #expect(cat.jiraTypes == ["Bug"] && cat.jiraStatuses == ["QA"] && cat.jiraPriorities.isEmpty)
        #expect(cat.adoTypes == ["Bug", "Task"] && cat.adoStates["Task"] == ["New"])
        #expect(err?.contains("jira priorities") == true)
        let (_, missing) = await Syncer(state: Store()).catalog(Connection(), jiraProjects: [], adoProjects: [])
        #expect(missing == "set the ADO organization in Settings first")
    }
}
