import Foundation

/// One issue's values, already transformed for ADO.
struct IssueFields {
    var wiType = "", title = "", description = "", start = "", target = "", priority = "", state = ""
    var area = "", iteration = "", key = "", createdBy = "", assignedTo = ""
    var originalEstimate = 0.0, remaining = 0.0, completed = 0.0  // hours, 0 = none
    var sprintUnknown = false  // Jira answered without the Sprint field, so its placement says nothing
    var parentID = 0
}

private struct UpdateResult {
    var done = false  // ADO has it Done: left alone (commented)
    var wrote = false  // something was sent: fields, the Removed reset or a conflict comment
    var rels: [Relation] = []  // the item's links before this update
}

extension SyncRun {
    /// Syncs one issue and reports what happened; a failure is a failed ticket, never a thrown error.
    /// details holds the batch-fetched issue; fetched says the batch answered, so a missing issue was filtered out by Jira.
    func process(_ issue: JiraIssue, _ details: [String: JiraIssue], fetched: Bool) async -> Ticket {
        calls = []
        var t = await processTicket(issue, details, fetched: fetched)
        t.calls = calls ?? []
        calls = nil
        return t
    }

    private func processTicket(_ issue: JiraIssue, _ details: [String: JiraIssue], fetched: Bool) async -> Ticket {
        var t = Ticket(key: issue.key)
        func fail(_ e: Error) -> Ticket {
            t.outcome = .failed
            t.error = describe(e)
            return t
        }
        var d = details[issue.id]
        if d == nil && !fetched {  // the batch failed: one search for this issue alone
            do { d = try await jira.search(scopedJQL("id = \(issue.id)"), fields: JiraClient.allFields).first } catch { return fail(error) }
        }
        guard let d else {
            t.message = "No detail returned from Jira"
            return t
        }
        t.key = d.key
        t.summary = d.summary
        t.parentKey = d.parent?.key ?? ""
        var f = fieldsOf(d)
        t.workItemType = f.wiType

        if job.filters.userFilter {
            let names = job.filters.assigneeList
            let pass = names.isEmpty ? !f.assignedTo.isEmpty : matchesAny(d.assignee, names)
            if !pass {
                t.message = "Skipped by user filter (assignee not in scope)"
                return t
            }
        }

        let existing: Int
        do {
            existing = try await findID(f.key)
            if let p = d.parent, !p.key.isEmpty { f.parentID = try await findID("\(p.key) - \(p.id)") }
        } catch { return fail(error) }

        var rels: [Relation] = []  // the item's current links, read once by update; none for a new item
        var wrote = true
        if existing != 0 {
            t.adoID = existing
            let res: UpdateResult
            do { res = try await update(existing, f, d) } catch { return fail(error) }
            rels = res.rels
            if res.done {
                t.message = firstRun ? "ADO #\(existing) is Done - skipped (first run imports the backlog, so no comment)"
                    : "ADO #\(existing) is Done - skipped update, commented instead"
                return t
            }
            wrote = res.wrote
            t.outcome = .updated
            t.message = dry ? "Would update ADO \(f.wiType) #\(existing)" : "Updated ADO \(f.wiType) #\(existing)"
        } else {
            let id: Int
            do { id = try await create(f) } catch { return fail(error) }
            ids[f.key] = id
            t.outcome = .created
            t.adoID = dry ? 0 : id
            t.message = dry ? "Would create a new ADO \(f.wiType)" : "Created ADO \(f.wiType) #\(id)"
        }

        // Attachment and comment failures don't fail the ticket, as in the source; they show up as warnings.
        var (written, warnings) = await syncAttachments(t.adoID, d.attachments, rels, created: existing == 0)
        if job.filters.syncComments {
            let (n, w) = await syncComments(d.key, t.adoID)
            written += n
            warnings += w
        }
        if !wrote && written == 0 {
            t.outcome = .skipped
            t.message = "ADO #\(existing) already up to date"
        } else if !wrote {
            t.message = "ADO #\(existing) fields already up to date; synced comments/attachments"
        }
        if !warnings.isEmpty { t.message += " · " + warnings.joined(separator: "; ") }
        return t
    }

    func fieldsOf(_ d: JiraIssue) -> IssueFields {
        var f = IssueFields(title: d.summary, description: adfToHTML(d.description), start: d.created, target: d.dueDate, key: "\(d.key) - \(d.id)")
        // Only the name counts as a sub-task here, as in the source; the subtask flag also covers Jira's other child types.
        let name = d.issueType
        let subtask = name.caseInsensitiveCompare("subtask") == .orderedSame || name.caseInsensitiveCompare("sub-task") == .orderedSame
        f.wiType = rules.workItemType(name, subtask: subtask)
        f.priority = rules.priority(d.priority)
        f.state = rules.state(f.wiType, d.status)
        if isTask(f.wiType) {
            f.originalEstimate = hours(d.timeOriginalEstimate)
            f.remaining = hours(d.timeEstimate)
            f.completed = hours(d.timeSpent)
        }
        (f.area, f.iteration) = job.paths(at: now())
        if job.filters.autoPaths {
            let inSprint = d.inActiveSprint(sprintFields)
            if inSprint != true {
                f.iteration = job.backlogPath  // out of sprint, or taken out of one: back to the backlog
                // Jira sent no sprint data: a new item still starts in the backlog, an existing one isn't moved there.
                f.sprintUnknown = inSprint == nil
            }
        }
        f.assignedTo = resolveEmail(d.assignee, job.filters.users)
        f.createdBy = resolveEmail(d.reporter, job.filters.users)
        return f
    }

    /// The JSON patch: empty values are dropped and only mapped fields are written.
    func ops(_ f: IssueFields) -> [PatchOp] {
        var all: [(String, Any)] = [
            (Field.title, "\(f.key) - \(f.title)"), (Field.description, f.description), (Field.startDate, f.start),
            (Field.priority, f.priority), (Field.state, f.state), (Field.area, f.area), (Field.iteration, f.iteration),
            (conn.jiraKeyField, f.key), (Field.createdBy, f.createdBy), (Field.assignedTo, f.assignedTo),
        ]
        if isTask(f.wiType) {  // Tasks get no due date, as in the source
            all += [(Field.originalEstimate, f.originalEstimate), (Field.remainingWork, f.remaining), (Field.completedWork, f.completed)]
        } else {
            all.append((Field.targetDate, f.target))
        }
        let always: Set = [Field.area, Field.iteration, conn.jiraKeyField]
        return all.filter { !isEmptyValue($0.1) && (always.contains($0.0) || job.writes($0.0)) }
            .map { PatchOp(op: "add", path: "/fields/" + $0.0, value: $0.1) }
    }

    /// Creates the work item in its first state, then moves it: ADO refuses to create one directly in a later state.
    func create(_ f: IssueFields) async throws -> Int {
        var initial = f
        initial.state = initialState(f.wiType)
        var ops = ops(initial)
        if f.parentID != 0 { ops.append(ado.parentRelation(f.parentID)) }
        let id = try await ado.create(type: f.wiType, ops: ops)
        if f.state != initial.state && job.writes(Field.state) { try await ado.update(id, ops: self.ops(f)) }
        return id
    }

    /// Reads the item once, then writes only fields whose value differs; ADO's Done wins and is only commented.
    private func update(_ id: Int, _ f: IssueFields, _ d: JiraIssue) async throws -> UpdateResult {
        var f = f
        let w = try await ado.get(id)
        var cur = w.fields
        var res = UpdateResult(rels: w.relations)
        let state = cur[Field.state] as? String ?? ""
        if state == "Done" {
            res.done = true
            if firstRun { return res }  // a backlog import would leave one comment on every old Done item
            _ = try await ado.addComment(id, html: "<p>Jira <b>\(escapeHTML(f.key))</b> vừa được cập nhật nhưng work item này đang ở trạng thái <b>Done</b> nên sync đã bỏ qua, không ghi đè. Vui lòng kiểm tra và cập nhật thủ công nếu cần.</p>")
            return res
        }
        // Removed can only go back to the first state; jumping straight to a later one is a 400.
        if state == "Removed" && f.state != "Removed" {
            try await ado.update(id, ops: [PatchOp(op: "add", path: "/fields/" + Field.state, value: initialState(f.wiType))])
            cur[Field.state] = initialState(f.wiType)
            res.wrote = true
        }

        if f.sprintUnknown {
            AppLog.warn("no Sprint field in Jira's answer; keeping the ADO iteration", ["key": f.key, "item": id])
            f.iteration = ""
        }
        if job.filters.keepIteration == true {
            if job.filters.commentIteration == true,
               try await noteIteration(id, want: f.iteration, have: cur[Field.iteration] as? String ?? "") { res.wrote = true }
            f.iteration = ""  // dropped by ops(): an ADO move isn't undone
        }

        // ADO is the source of truth for these once filled: the sync keeps them and comments the difference.
        var conflicts: [String] = []
        func keep(_ field: String, _ jiraValue: Any) -> Bool {
            guard let adoValue = cur[field], !isEmptyValue(adoValue) else { return false }
            if !isEmptyValue(jiraValue) && !sameValue(adoValue, jiraValue) {
                let name = field.split(separator: ".").last.map(String.init) ?? field
                conflicts.append("\(name): ADO <b>\(escapeHTML(fmtAny(adoValue)))</b> — Jira <b>\(escapeHTML(fmtAny(jiraValue)))</b>")
            }
            return true
        }
        if keep(Field.targetDate, f.target) { f.target = "" }
        if keep(Field.originalEstimate, hours(d.timeOriginalEstimate)) { f.originalEstimate = 0 }
        if keep(Field.completedWork, hours(d.timeSpent)) { f.completed = 0 }

        var ops = changedOps(ops(f), cur)
        if f.parentID != 0 && !hasParent(w.relations, f.parentID) { ops.append(ado.parentRelation(f.parentID)) }
        if !ops.isEmpty {
            try await ado.update(id, ops: ops)
            res.wrote = true
        }
        if !conflicts.isEmpty {
            _ = try await ado.addComment(id, html: "<p>Sync từ Jira <b>\(escapeHTML(f.key))</b> không ghi đè các field đã có giá trị trên ADO:</p><ul><li>\(conflicts.joined(separator: "</li><li>"))</li></ul>")
            res.wrote = true
        }
        return res
    }

    /// Says once per target iteration that Jira moved the issue (a late sprint, say) while ADO's placement was kept.
    // ponytail: the comment mappings table doubles as the "already said this" marker; its own table if more notes appear
    private func noteIteration(_ id: Int, want: String, have: String) async throws -> Bool {
        guard !want.isEmpty, want != have else { return false }
        let mapped = try state.commentMappings(workItem: id)
        guard mapped[Self.iterationNote]?.jiraUpdated != want else { return false }
        let commentID = try await ado.addComment(id, html: "<p>Jira xếp issue này vào <b>\(escapeHTML(want))</b>, nhưng iteration trên ADO (<b>\(escapeHTML(have))</b>) được giữ nguyên. Chuyển thủ công nếu cần.</p>")
        try state.saveCommentMapping(CommentMapping(workItemID: id, jiraCommentID: Self.iterationNote, adoCommentID: commentID, jiraUpdated: want))
        return true
    }

    static let iterationNote = "sync:iteration"

    /// Replaces the item's ADO attachments with Jira's; with none in Jira it does nothing, so files attached in ADO stay.
    // ponytail: re-uploads all files when Jira has any, like the source; diff by name+size if uploads get slow
    func syncAttachments(_ id: Int, _ atts: [JiraAttachment], _ rels: [Relation], created: Bool) async -> (Int, [String]) {
        guard !atts.isEmpty else { return (0, []) }
        var warnings: [String] = []
        if !created && rels.contains(where: { $0.rel == "AttachedFile" }) {
            do { try await ado.removeAttachments(id, rels) } catch { warnings.append("remove attachments: " + describe(error)) }
        }
        var written = 0
        for a in atts {
            do {
                // A dry run doesn't download either: it only needs the names.
                let data = dry ? Data() : try await jira.download(a.content)
                try await ado.attach(id, name: a.filename, data: data)
                written += 1
            } catch { warnings.append("attach \(a.filename): " + describe(error)) }
        }
        return (written, warnings)
    }

    /// Copies new Jira comments and patches edited ones in place; comments deleted in Jira are left alone.
    func syncComments(_ key: String, _ id: Int) async -> (Int, [String]) {
        let comments: [JiraComment]
        do { comments = try await jira.comments(key) } catch { return (0, ["comments: " + describe(error)]) }
        guard !comments.isEmpty else { return (0, []) }
        var mapped: [String: CommentMapping]
        do { mapped = try state.commentMappings(workItem: id) } catch { return (0, ["comment mappings: " + describe(error)]) }
        var written = 0, warnings: [String] = []
        for c in comments {
            do {
                if var m = mapped[c.id] {
                    guard !c.updated.isEmpty && c.updated != m.jiraUpdated else { continue }
                    try await ado.updateComment(id, commentID: m.adoCommentID, html: renderComment(c, edited: true))
                    m.jiraUpdated = c.updated
                    try state.saveCommentMapping(m)
                    mapped[c.id] = m
                } else {
                    let cid = try await ado.addComment(id, html: renderComment(c, edited: false))
                    try state.saveCommentMapping(CommentMapping(workItemID: id, jiraCommentID: c.id, adoCommentID: cid, jiraUpdated: c.updated))
                }
                written += 1
            } catch { warnings.append("comment \(c.id): " + describe(error)) }
        }
        return (written, warnings)
    }
}

/// Drops the field ops whose value ADO already has, so an unchanged item gets no PATCH, revision or notification.
func changedOps(_ ops: [PatchOp], _ cur: JSONObject) -> [PatchOp] {
    ops.filter { op in
        guard op.path.hasPrefix("/fields/") else { return true }
        let field = String(op.path.dropFirst("/fields/".count))
        return !sameADOValue(field, cur[field], op.value as Any)
    }
}

/// Compares what ADO returns for a field with what the sync would write.
/// When unsure it answers false: an extra write is harmless, a skipped one loses a change.
func sameADOValue(_ field: String, _ have: Any?, _ want: Any) -> Bool {
    guard let have, !(have is NSNull) else { return isEmptyValue(want) }
    switch field {
    case Field.assignedTo, Field.createdBy:  // ADO returns an identity object
        if let m = have as? JSONObject {
            let u = m["uniqueName"] as? String ?? ""
            return !u.isEmpty && u.caseInsensitiveCompare(want as? String ?? "") == .orderedSame
        }
    case Field.startDate:  // same instant, written with a different offset
        guard let h = parseJiraTime(have as? String ?? ""), let w = parseJiraTime(want as? String ?? "") else { return false }
        return h == w
    case Field.targetDate:
        return sameValue(have, want)
    case Field.description:
        return normalizeHTML(have as? String ?? "") == normalizeHTML(want as? String ?? "")
    case Field.area, Field.iteration:
        return (have as? String ?? "").caseInsensitiveCompare(want as? String ?? "") == .orderedSame
    default: break
    }
    if number(have) != nil { return sameValue(have, want) }
    return fmtAny(have) == fmtAny(want)
}

/// Evens out what ADO rewrites in stored HTML (void tags, whitespace) before comparing.
func normalizeHTML(_ s: String) -> String {
    var s = s
    for (a, b) in [("<br/>", "<br>"), ("<br />", "<br>"), ("<hr/>", "<hr>"), ("<hr />", "<hr>")] { s = s.replacingOccurrences(of: a, with: b) }
    return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// Renders the Jira author first, since the ADO comment is posted as the PAT's user.
func renderComment(_ c: JiraComment, edited: Bool) -> String {
    let author = c.author?.displayName.isEmpty == false ? c.author!.displayName : "Unknown"
    return "<div><p><strong>[\(escapeHTML(author))]:</strong>\(edited ? " <em>(edited)</em>" : "")</p>\(adfToHTML(c.body))</div>"
}

/// Maps a Jira user (email or display name, case-insensitive) to its ADO email, or "".
func resolveEmail(_ u: JiraUser?, _ users: [UserPair]) -> String {
    users.first { matches(u, $0.jira) }?.adoEmail ?? ""
}

func matches(_ u: JiraUser?, _ needle: String) -> Bool {
    let n = needle.trimmingCharacters(in: .whitespaces).lowercased()
    guard let u, !n.isEmpty else { return false }
    return u.email.trimmingCharacters(in: .whitespaces).lowercased() == n || u.displayName.trimmingCharacters(in: .whitespaces).lowercased() == n
}

func matchesAny(_ u: JiraUser?, _ names: [String]) -> Bool { names.contains { matches(u, $0) } }

/// Jira seconds → ADO hours with 2 decimals; 0 for none.
func hours(_ seconds: Double) -> Double {
    guard seconds > 0, seconds.isFinite else { return 0 }
    return (seconds / 3600 * 100).rounded() / 100
}

/// A JSON number (not a bool), as Double.
func number(_ v: Any?) -> Double? {
    if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
    return v as? Double
}

func isEmptyValue(_ v: Any?) -> Bool {
    guard let v, !(v is NSNull) else { return true }
    if let s = v as? String { return s.isEmpty }
    if let n = number(v) { return n == 0 }
    return false
}

/// Compares numbers numerically and anything else by its date part, since ADO returns full ISO dates.
func sameValue(_ ado: Any, _ jira: Any) -> Bool {
    let an = number(ado), jn = number(jira)
    if an != nil || jn != nil {
        let a = an ?? toDouble(ado), j = jn ?? toDouble(jira)
        return a == j  // NaN never equals anything
    }
    return fmtAny(ado).prefix(10) == fmtAny(jira).prefix(10)
}

/// The source's Number(x) for the side that isn't already a number.
private func toDouble(_ v: Any) -> Double {
    (v as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? .nan
}

/// A value as Go's fmt.Sprint shows it: 3.0 → "3".
func fmtAny(_ v: Any?) -> String {
    guard let v, !(v is NSNull) else { return "" }
    if let s = v as? String { return s }
    if let n = number(v) { return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n) }
    return "\(v)"
}
