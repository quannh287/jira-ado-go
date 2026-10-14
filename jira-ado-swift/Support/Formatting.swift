import Foundation

/// One ADO field a ticket's run wrote, with its final value.
struct SyncedField: Hashable {
    var name: String
    var value: String
}

/// Reads a ticket's ADO calls back into what changed: fields written (last write wins) and side effects.
func synced(_ calls: [APICall]) -> (fields: [SyncedField], notes: [String]) {
    var fields: [SyncedField] = [], index: [String: Int] = [:]
    var comments = 0, edited = 0, attached = 0, parent = false
    for c in calls where c.status < 400 && c.error.isEmpty {  // a failed write changed nothing
        if c.url.contains("/comments") {
            if c.method == "POST" { comments += 1 } else if c.method == "PATCH" { edited += 1 }
            continue
        }
        // Uploads are counted by the relation that links them.
        guard !c.url.contains("/attachments"), c.method == "POST" || c.method == "PATCH",
              let ops = parseJSON(Data(c.request.utf8)) as? [JSONObject] else { continue }
        for op in ops {
            let path = op["path"] as? String ?? ""
            if path.hasPrefix("/fields/") {
                let field = String(path.dropFirst("/fields/".count)), v = oneLine(op["value"])
                if let i = index[field] { fields[i].value = v } else {
                    index[field] = fields.count
                    fields.append(SyncedField(name: field, value: v))
                }
            } else if path == "/relations/-", let rel = (op["value"] as? JSONObject)?["rel"] as? String {
                if rel == "AttachedFile" { attached += 1 }
                if rel == "System.LinkTypes.Hierarchy-Reverse" { parent = true }
            }
        }
    }
    for i in fields.indices { fields[i].name = fields[i].name.split(separator: ".").last.map(String.init) ?? fields[i].name }
    var notes: [String] = []
    if parent { notes.append("Linked to parent") }
    if attached > 0 { notes.append(plural(attached, "attachment") + " uploaded") }
    if comments > 0 { notes.append(plural(comments, "comment") + " added") }
    if edited > 0 { notes.append(plural(edited, "comment") + " updated") }
    return (fields, notes)
}

/// A field value (HTML descriptions included) as a short single line.
func oneLine(_ v: Any?) -> String {
    var s = fmtAny(v).replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
    for (e, c) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
        s = s.replacingOccurrences(of: e, with: c)
    }
    s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return s.count > 90 ? s.prefix(90) + "…" : s
}

func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }

/// Drops the host and api-version, leaving what was called.
func shortURL(_ u: String) -> String {
    var u = u
    if let r = u.range(of: "/_apis/") { u = String(u[u.index(before: r.upperBound)...]) }
    if let r = u.range(of: "api-version=") {
        u = String(u[..<r.lowerBound])
        while u.hasSuffix("?") || u.hasSuffix("&") { u.removeLast() }
    }
    return u
}

/// The Jira browse link for key, or nil without a site URL.
func issueURL(_ site: String, _ key: String) -> URL? {
    guard !site.isEmpty, !key.isEmpty else { return nil }
    return URL(string: trimSlash(site) + "/browse/" + pathEscape(key))
}

/// The ADO web link for a work item, or nil when it has none yet.
func workItemURL(_ org: String, _ project: String, _ id: Int) -> URL? {
    guard !org.isEmpty, !project.isEmpty, id > 0 else { return nil }
    return URL(string: "https://dev.azure.com/\(pathEscape(org))/\(pathEscape(project))/_workitems/edit/\(id)")
}

/// A top-level ticket (or a parent that isn't in the run) with its sub-tasks.
struct TicketGroup: Hashable {
    var parent: Int?  // index into the run's tickets; nil when the parent wasn't synced in this run
    var parentKey: String
    var children: [Int] = []
}

/// Nests sub-tasks under their parent, in the order tickets first appear.
func groupTickets(_ tickets: [Ticket]) -> [TicketGroup] {
    var byKey: [String: Int] = [:]
    for (i, t) in tickets.enumerated() { byKey[t.key] = i }
    var groups: [TicketGroup] = [], at: [String: Int] = [:]
    func group(_ key: String, _ parent: Int?) -> Int {
        if let g = at[key] { return g }
        at[key] = groups.count
        groups.append(TicketGroup(parent: parent, parentKey: key))
        return groups.count - 1
    }
    for (i, t) in tickets.enumerated() {
        if !t.parentKey.isEmpty {
            // A parent not synced in this run still gets a header that gathers its sub-tasks.
            let p = byKey[t.parentKey].flatMap { $0 != i ? $0 : nil }
            groups[group(t.parentKey, p)].children.append(i)
            continue
        }
        groups[group(t.key, i)].parent = i  // a sub-task listed before its parent created the group without one
    }
    return groups
}

// MARK: - Formatting

func ago(_ t: Date, _ now: Date) -> String {
    let d = now.timeIntervalSince(t)
    switch d {
    case ..<60: return "just now"
    case ..<3600: return "\(Int(d / 60))m ago"
    case ..<86400: return "\(Int(d / 3600))h ago"
    default: return "\(Int(d / 86400))d ago"
    }
}

/// 0.8s, 12.3s, 2m5.1s — as Go's rounded Duration.
func fmtDuration(_ d: TimeInterval) -> String {
    let d = (d * 10).rounded() / 10
    if d < 60 { return "\(fmtAny(d))s" }
    let m = Int(d / 60)
    return "\(m)m\(fmtAny(((d - Double(m * 60)) * 10).rounded() / 10))s"
}

/// "1 created · 8 updated · 6 skipped · 0 failed".
func fmtRunCounts(_ r: Run) -> String { Outcome.allCases.map { "\(r.count($0)) \($0.rawValue)" }.joined(separator: " · ") }

func fmtRunSummary(_ r: Run) -> String { Outcome.allCases.map { "\(r.count($0)) \($0.rawValue)" }.joined(separator: ", ") }

/// "12 of 71 issues" once Jira answered, "Searching Jira…" before.
func progressText(_ p: SyncProgress) -> String { p.total == 0 ? "Searching Jira…" : "\(p.done) of \(p.total) issues" }

func kindLabel(_ k: RunKind) -> String {
    switch k {
    case .dryRun: "dry run"
    case .retry: "retry"
    case .sync: ""
    }
}

let everyMinutes = [15, 30, 60, 180, 360, 720, 1440]
let everyLabels = ["15 minutes", "30 minutes", "1 hour", "3 hours", "6 hours", "12 hours", "24 hours"]

/// An interval as the Run every picker labels it, or in plain minutes.
func fmtEvery(_ d: TimeInterval) -> String {
    let m = Int(d / 60)
    return everyMinutes.firstIndex(of: m).map { everyLabels[$0] } ?? "\(m) minutes"
}

/// The job's sync type, with the interval for Scheduler jobs.
func syncTypeLabel(_ j: Job) -> String {
    j.type == .scheduler ? "Scheduler · every " + fmtEvery(j.filters.every) : j.type.rawValue
}

/// Notification IDs are "run/<job>/<run>", so a click, even one that relaunches the app, knows what to open.
func notificationID(_ job: Int, _ run: Int) -> String { "run/\(job)/\(run)" }

func parseNotificationID(_ id: String) -> (job: Int, run: Int)? {
    let p = id.split(separator: "/")
    guard p.count == 3, p[0] == "run", let j = Int(p[1]), let r = Int(p[2]) else { return nil }
    return (j, r)
}
