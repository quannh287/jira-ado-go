import Foundation

struct JiraUser {
    var email = "", displayName = ""
    init?(_ v: Any?) {
        guard let o = v as? JSONObject else { return nil }
        email = o["emailAddress"] as? String ?? ""
        displayName = o["displayName"] as? String ?? ""
    }
    init(email: String, displayName: String) { self.email = email; self.displayName = displayName }
}

struct JiraRef { var id = "", key = "" }

struct JiraAttachment { var filename = "", content = "" }  // content is the download URL

/// A Jira issue; raw keeps every field, for custom fields whose ID differs per site, such as Sprint.
struct JiraIssue {
    var id = ""
    var key = ""
    var raw: JSONObject = [:]

    init(id: String, key: String, fields: JSONObject = [:]) { self.id = id; self.key = key; raw = fields }

    init(_ o: JSONObject) {
        id = o["id"] as? String ?? ""
        key = o["key"] as? String ?? ""
        raw = o["fields"] as? JSONObject ?? [:]
    }

    private func name(_ f: String) -> String { (raw[f] as? JSONObject)?["name"] as? String ?? "" }
    var summary: String { raw["summary"] as? String ?? "" }
    var description: Any? { raw["description"] }  // ADF
    var created: String { raw["created"] as? String ?? "" }
    var updated: String { raw["updated"] as? String ?? "" }
    var dueDate: String { raw["duedate"] as? String ?? "" }
    var priority: String { name("priority") }
    var status: String { name("status") }
    var issueType: String { name("issuetype") }
    var isSubtaskType: Bool { (raw["issuetype"] as? JSONObject)?["subtask"] as? Bool ?? false }
    var parent: JiraRef? {
        (raw["parent"] as? JSONObject).map { JiraRef(id: $0["id"] as? String ?? "", key: $0["key"] as? String ?? "") }
    }
    var assignee: JiraUser? { JiraUser(raw["assignee"]) }
    var reporter: JiraUser? { JiraUser(raw["reporter"]) }
    var subtasks: [JiraRef] {
        (raw["subtasks"] as? [JSONObject] ?? []).map { JiraRef(id: $0["id"] as? String ?? "", key: $0["key"] as? String ?? "") }
    }
    private func seconds(_ f: String) -> Double { (raw[f] as? NSNumber)?.doubleValue ?? 0 }
    var timeEstimate: Double { seconds("aggregatetimeestimate") }
    var timeOriginalEstimate: Double { seconds("aggregatetimeoriginalestimate") }
    var timeSpent: Double { seconds("aggregatetimespent") }
    var attachments: [JiraAttachment] {
        (raw["attachment"] as? [JSONObject] ?? []).map { JiraAttachment(filename: $0["filename"] as? String ?? "", content: $0["content"] as? String ?? "") }
    }

    /// Whether the issue sits in a sprint that has started and not closed; nil when Jira sent no sprint data
    /// at all, which is unknown, not out of sprint - an account that can't read the field would empty every sprint.
    func inActiveSprint(_ sprintFields: [String], futureCounts: Bool = false) -> Bool? {
        guard sprintFields.contains(where: { raw.index(forKey: $0) != nil }) else { return nil }
        let states = futureCounts ? ["active", "future"] : ["active"]
        return sprintFields.contains { f in
            (raw[f] as? [JSONObject] ?? []).contains { states.contains(($0["state"] as? String)?.lowercased() ?? "") }
        }
    }
}

struct JiraComment {
    var id = ""
    var author: JiraUser?
    var body: Any?  // ADF
    var updated = ""
}

/// The Jira Cloud REST v3 calls the sync needs.
final class JiraClient {
    private let h: HTTPClient

    init(baseURL: String, email: String, token: String) {
        h = HTTPClient(base: trimSlash(baseURL) + "/rest/api/3", auth: basicAuth(email, token))
    }

    static let allFields = ["*all"]

    /// Every Jira Software Sprint field (e.g. customfield_10020); a migrated site can list more than one.
    func sprintFields() async throws -> [String] {
        let fields = try await json("GET", "/field") as? [JSONObject] ?? []
        return fields.filter { ($0["schema"] as? JSONObject)?["custom"] as? String == "com.pyxis.greenhopper.jira:gh-sprint" }
            .compactMap { $0["id"] as? String }
    }

    /// Pages through POST /search/jql with nextPageToken.
    func search(_ jql: String, fields: [String]) async throws -> [JiraIssue] {
        var all: [JiraIssue] = [], token = ""
        while true {
            var body: JSONObject = ["jql": jql, "maxResults": 100, "fields": fields]
            if !token.isEmpty { body["nextPageToken"] = token }
            let page: JSONObject
            do { page = try await json("POST", "/search/jql", body) as? JSONObject ?? [:] } catch {
                throw Failure("jira search \(jqlQuote(jql)): \(describe(error))")
            }
            all += (page["issues"] as? [JSONObject] ?? []).map(JiraIssue.init)
            token = page["nextPageToken"] as? String ?? ""
            if page["isLast"] as? Bool == true || token.isEmpty { return all }
        }
    }

    /// Pages through /issue/{key}/comment; the comment field on search results is incomplete.
    func comments(_ key: String) async throws -> [JiraComment] {
        var all: [JiraComment] = [], start = 0
        while true {
            let page: JSONObject
            do {
                page = try await json("GET", "/issue/\(pathEscape(key))/comment?startAt=\(start)&maxResults=100&orderBy=created") as? JSONObject ?? [:]
            } catch { throw Failure("jira comments \(key): \(describe(error))") }
            let got = (page["comments"] as? [JSONObject] ?? []).map {
                JiraComment(id: $0["id"] as? String ?? "", author: JiraUser($0["author"]), body: $0["body"], updated: $0["updated"] as? String ?? "")
            }
            all += got
            start += got.count
            if got.isEmpty || start >= (page["total"] as? Int ?? 0) { return all }
        }
    }

    func download(_ url: String) async throws -> Data {
        let (resp, err) = await h.send("GET", url)
        if let err { throw err }
        return resp.body
    }

    /// A project's issue types and the statuses their workflows use, in Jira's order.
    func projectStatuses(_ project: String) async throws -> (types: [String], statuses: [String]) {
        let out: [JSONObject]
        do { out = try await json("GET", "/project/\(pathEscape(project))/statuses") as? [JSONObject] ?? [] } catch {
            throw Failure("jira statuses of \(project): \(describe(error))")
        }
        let types = out.compactMap { $0["name"] as? String }
        let statuses = out.flatMap { ($0["statuses"] as? [JSONObject] ?? []).compactMap { $0["name"] as? String } }
        return (types, statuses)
    }

    /// The site's priority names, highest first.
    func priorities() async throws -> [String] {
        do { return (try await json("GET", "/priority") as? [JSONObject] ?? []).compactMap { $0["name"] as? String } } catch {
            throw Failure("jira priorities: \(describe(error))")
        }
    }

    /// The account's time zone, the one Jira reads JQL dates in.
    func timeZone() async throws -> TimeZone {
        let u = try await json("GET", "/myself") as? JSONObject ?? [:]
        guard let id = u["timeZone"] as? String, !id.isEmpty else { return TimeZone(identifier: "UTC")! }
        guard let tz = TimeZone(identifier: id) else { throw Failure("unknown time zone \(id)") }
        return tz
    }

    /// Checks the credentials and returns the account's display name.
    func myself() async throws -> String {
        (try await json("GET", "/myself") as? JSONObject)?["displayName"] as? String ?? ""
    }

    private func json(_ method: String, _ path: String, _ body: Any? = nil) async throws -> Any {
        let (resp, err) = await h.send(method, path, contentType: "application/json", body: body.map { jsonData($0) })
        if let err { throw err }
        guard let v = parseJSON(resp.body) else { throw Failure("decode \(method) \(path): invalid JSON") }
        return v
    }
}

/// JQL strings take JSON-style escapes.
func jqlQuote(_ s: String) -> String { String(decoding: jsonData(s), as: UTF8.self) }

func trimSlash(_ s: String) -> String {
    var s = s
    while s.hasSuffix("/") { s.removeLast() }
    return s
}
