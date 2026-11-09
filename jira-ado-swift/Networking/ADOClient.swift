import Foundation

/// One JSON-patch operation; a nil value is omitted.
struct PatchOp {
    var op: String
    var path: String
    var value: Any?

    var json: JSONObject {
        var o: JSONObject = ["op": op, "path": path]
        if let value { o["value"] = value }
        return o
    }
}

struct Relation {
    var rel: String
    var url: String
}

/// A work item's current fields and relations.
struct WorkItem {
    var fields: JSONObject = [:]
    var relations: [Relation] = []
}

/// Whether the relations already link the item under parentID.
func hasParent(_ rels: [Relation], _ parentID: Int) -> Bool {
    let suffix = "/workitems/\(parentID)"
    return rels.contains { $0.rel == "System.LinkTypes.Hierarchy-Reverse" && $0.url.lowercased().hasSuffix(suffix) }
}

/// The Azure DevOps work-item REST calls the sync needs. Every call is reported to onCall for the run report.
final class ADOClient {
    static var host = "https://dev.azure.com"  // tests point it elsewhere
    private static let apiVersion = "7.1-preview"
    private static let commentsAPIVersion = "7.1-preview.4"  // comments are preview-only
    private static let maxLoggedBody = 16 << 10

    let org: String, project: String
    private let h: HTTPClient
    var onCall: ((APICall) -> Void)?

    init(org: String, project: String, pat: String) {
        self.org = org
        self.project = project
        h = HTTPClient(base: "\(Self.host)/\(pathEscape(org))/\(pathEscape(project))/_apis", auth: patAuth(pat))
    }

    /// Validates the PAT at the organization level and returns the user's display name.
    static func connectionData(org: String, pat: String) async throws -> String {
        let (resp, err) = await HTTPClient(base: "", auth: patAuth(pat)).send("GET", "\(host)/\(pathEscape(org))/_apis/connectionData")
        if let err { throw err }
        // An invalid PAT can be redirected to an HTML sign-in page that still returns 2xx.
        guard let user = (parseJSON(resp.body) as? JSONObject)?["authenticatedUser"] as? JSONObject,
              let id = user["id"] as? String, !id.isEmpty, id != "00000000-0000-0000-0000-000000000000" else {
            throw Failure("ADO rejected the personal access token")
        }
        return user["providerDisplayName"] as? String ?? ""
    }

    /// The work item whose field equals value, or 0.
    func find(field: String, value: String) async throws -> Int {
        let q = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '\(wiqlEscape(project))' AND [\(field)] = '\(wiqlEscape(value))'"
        let out = try await send("POST", "/wit/wiql?api-version=\(Self.apiVersion)", "application/json", ["query": q]) as? JSONObject
        return ((out?["workItems"] as? [JSONObject])?.first?["id"] as? Int) ?? 0
    }

    /// Every work item id the query returns, in its order.
    func wiql(_ query: String) async throws -> [Int] {
        let out = try await send("POST", "/wit/wiql?api-version=\(Self.apiVersion)", "application/json", ["query": query]) as? JSONObject
        return (out?["workItems"] as? [JSONObject] ?? []).compactMap { $0["id"] as? Int }
    }

    /// The live fields of each id. WIQL's index lags writes both ways, so its ids are candidates only — filter on these.
    func batch(_ ids: [Int], fields: [String]) async throws -> [JSONObject] {
        var out: [JSONObject] = []
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            let body: JSONObject = ["ids": chunk, "fields": fields, "errorPolicy": "omit"]
            let o = try await send("POST", "/wit/workitemsbatch?api-version=\(Self.apiVersion)", "application/json", body) as? JSONObject
            out += (o?["value"] as? [JSONObject] ?? [])
        }
        return out
    }

    /// The iterations directly under a base path, with their dates. The team-scoped iterations API sits outside this
    /// client's project base URL, so the classification tree answers it instead — and needs no team name.
    func iterations(under base: String) async throws -> [Iteration] {
        let parts = base.trimmingCharacters(in: CharacterSet(charactersIn: "\\")).components(separatedBy: "\\")
        let rest = parts.dropFirst().map(pathEscape).joined(separator: "/")
        let o = try await send("GET", "/wit/classificationnodes/iterations/\(rest)?$depth=1&api-version=\(Self.apiVersion)") as? JSONObject
        return (o?["children"] as? [JSONObject] ?? []).compactMap { c in
            let attrs = c["attributes"] as? JSONObject ?? [:]
            guard let name = c["name"] as? String,
                  let start = parseJiraTime(attrs["startDate"] as? String ?? ""),
                  let finish = parseJiraTime(attrs["finishDate"] as? String ?? "") else { return nil }
            return Iteration(path: base + "\\" + name, start: start, finish: finish)
        }.sorted { $0.start < $1.start }
    }

    /// Whether an area or iteration path exists. kind is "areas" or "iterations"; path starts with the project name.
    func nodeExists(kind: String, path: String) async throws -> Bool {
        let parts = path.trimmingCharacters(in: CharacterSet(charactersIn: "\\")).components(separatedBy: "\\")
        guard let first = parts.first, first.caseInsensitiveCompare(project) == .orderedSame else { return false }
        let rest = parts.dropFirst().map(pathEscape).joined(separator: "/")
        let (_, err) = await h.send("GET", "/wit/classificationnodes/\(kind)/\(rest)?$depth=0&api-version=\(Self.apiVersion)")
        if let e = err as? HTTPStatusError, e.status == 404 { return false }
        if let err { throw err }
        return true
    }

    /// The project's enabled work item types.
    func workItemTypes() async throws -> [String] {
        let out = try await send("GET", "/wit/workitemtypes?api-version=\(Self.apiVersion)") as? JSONObject
        return (out?["value"] as? [JSONObject] ?? []).filter { $0["isDisabled"] as? Bool != true }.compactMap { $0["name"] as? String }
    }

    /// A work item type's states in workflow order.
    func states(_ type: String) async throws -> [String] {
        let out = try await send("GET", "/wit/workitemtypes/\(pathEscape(type))/states?api-version=\(Self.apiVersion)") as? JSONObject
        return (out?["value"] as? [JSONObject] ?? []).compactMap { $0["name"] as? String }
    }

    /// Every field and relation in one call ($expand can't be combined with a field list).
    func get(_ id: Int) async throws -> WorkItem {
        let o = try await send("GET", "/wit/workitems/\(id)?$expand=relations&api-version=\(Self.apiVersion)") as? JSONObject ?? [:]
        let rels = (o["relations"] as? [JSONObject] ?? []).map { Relation(rel: $0["rel"] as? String ?? "", url: $0["url"] as? String ?? "") }
        return WorkItem(fields: o["fields"] as? JSONObject ?? [:], relations: rels)
    }

    /// The work item's revision history, newest first.
    func updates(_ id: Int) async throws -> [Revision] {
        let o = try await send("GET", "/wit/workitems/\(id)/updates?api-version=\(Self.apiVersion)") as? JSONObject ?? [:]
        return (o["value"] as? [JSONObject] ?? []).map(Self.revision).sorted { $0.id > $1.id }
    }

    /// Fields ADO rewrites on its own; showing them would bury the edit that was actually made.
    private static let derivedFields: Set<String> = [
        "System.Rev", "System.AuthorizedDate", "System.RevisedDate", "System.Watermark", "System.ChangedDate",
        "System.ChangedBy", "System.AuthorizedAs", "System.PersonId", "System.AreaId", "System.IterationId",
        "System.CommentCount", "System.BoardColumn", "System.BoardColumnDone", "System.IsDeleted",
    ]

    /// An identity field is an object; everything else goes through the plain one-line form.
    private static func identityOrText(_ v: Any?) -> String {
        if let o = v as? JSONObject, let name = o["displayName"] as? String { return name }
        return oneLine(v)
    }

    private static func revision(_ u: JSONObject) -> Revision {
        let fields = u["fields"] as? JSONObject ?? [:]
        let by = (u["revisedBy"] as? JSONObject)?["displayName"] as? String ?? ""
        let changed = (fields["System.ChangedDate"] as? JSONObject)?["newValue"] as? String
        var r = Revision(id: u["id"] as? Int ?? 0, rev: u["rev"] as? Int ?? 0,
                         at: parseJiraTime(changed ?? u["revisedDate"] as? String ?? "") ?? .distantPast,
                         by: by.split(separator: " <").first.map(String.init) ?? by)
        for (name, v) in fields.sorted(by: { $0.key < $1.key }) {
            guard !derivedFields.contains(name), !name.hasPrefix("WEF_"),
                  !name.contains("AreaLevel"), !name.contains("IterationLevel"), let v = v as? JSONObject else { continue }
            if name == "System.History" {
                r.changes.append("comment")
                continue
            }
            let short = name.split(separator: ".").last.map(String.init) ?? name
            let old = identityOrText(v["oldValue"]), new = identityOrText(v["newValue"])
            r.changes.append(old.isEmpty ? "\(short): \(new)" : "\(short): \(old) → \(new)")
        }
        return r
    }

    func create(type: String, ops: [PatchOp]) async throws -> Int {
        let out = try await send("POST", "/wit/workitems/$\(pathEscape(type))?api-version=\(Self.apiVersion)", "application/json-patch+json", ops.map(\.json))
        return (out as? JSONObject)?["id"] as? Int ?? 0
    }

    func update(_ id: Int, ops: [PatchOp]) async throws {
        _ = try await send("PATCH", "/wit/workitems/\(id)?api-version=\(Self.apiVersion)", "application/json-patch+json", ops.map(\.json))
    }

    /// Links a work item under parentID.
    func parentRelation(_ parentID: Int) -> PatchOp {
        PatchOp(op: "add", path: "/relations/-", value: [
            "rel": "System.LinkTypes.Hierarchy-Reverse",
            "url": "\(Self.host)/\(pathEscape(org))/\(pathEscape(project))/_apis/wit/workItems/\(parentID)",
        ])
    }

    /// Drops every AttachedFile relation, given the relations read by get; links added since went to the end.
    func removeAttachments(_ id: Int, _ rels: [Relation]) async throws {
        let ops = rels.indices.reversed().filter { rels[$0].rel == "AttachedFile" }.map { PatchOp(op: "remove", path: "/relations/\($0)") }
        if !ops.isEmpty { try await update(id, ops: ops) }
    }

    /// Uploads data and links it to the work item.
    func attach(_ id: Int, name: String, data: Data) async throws {
        let path = "/wit/attachments?fileName=\(queryEscape(name))&api-version=\(Self.apiVersion)"
        let (resp, err) = await h.send("POST", path, contentType: "application/octet-stream", body: data)
        log("POST", path, "<\(data.count) bytes>", resp, err)
        if let err { throw err }
        guard let url = (parseJSON(resp.body) as? JSONObject)?["url"] as? String else { throw Failure("decode attachment upload") }
        try await update(id, ops: [PatchOp(op: "add", path: "/relations/-", value: ["rel": "AttachedFile", "url": url, "attributes": ["name": name]])])
    }

    func addComment(_ id: Int, html: String) async throws -> Int {
        let out = try await send("POST", "/wit/workItems/\(id)/comments?api-version=\(Self.commentsAPIVersion)", "application/json", ["text": html])
        return (out as? JSONObject)?["id"] as? Int ?? 0
    }

    func updateComment(_ id: Int, commentID: Int, html: String) async throws {
        _ = try await send("PATCH", "/wit/workItems/\(id)/comments/\(commentID)?api-version=\(Self.commentsAPIVersion)", "application/json", ["text": html])
    }

    private func send(_ method: String, _ path: String, _ contentType: String = "", _ body: Any? = nil) async throws -> Any? {
        let data = body.map { jsonData($0, pretty: true) }
        let (resp, err) = await h.send(method, path, contentType: contentType, body: data)
        log(method, path, data.map { String(decoding: $0, as: UTF8.self) } ?? "", resp, err)
        if let err { throw err }
        if resp.body.isEmpty { return nil }
        guard let v = parseJSON(resp.body) else { throw Failure("decode \(method) \(path): invalid JSON") }
        return v
    }

    private func log(_ method: String, _ path: String, _ req: String, _ resp: HTTPResponse, _ err: Error?) {
        guard let onCall else { return }
        var call = APICall(method: method, url: h.base + path, request: req, status: resp.status, response: clip(resp.body),
                           retries: resp.retries, duration: resp.duration)
        if let err { call.error = describe(err) }
        onCall(call)
    }

    private func clip(_ b: Data) -> String {
        b.count > Self.maxLoggedBody ? String(decoding: b.prefix(Self.maxLoggedBody), as: UTF8.self) + "\n…(truncated)" : String(decoding: b, as: UTF8.self)
    }
}

func patAuth(_ pat: String) -> String { basicAuth("", pat) }

/// Doubles single quotes so a Jira key can't break out of the WIQL string.
func wiqlEscape(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }
