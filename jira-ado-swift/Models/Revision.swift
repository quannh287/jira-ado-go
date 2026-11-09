import Foundation

/// One ADO work item revision and who wrote it. ADO itself can't tell a PAT write from a web edit:
/// both carry the same identity, so the source is recovered from this app's own call log.
struct Revision: Identifiable, Hashable {
    var id = 0  // the update's own id; two updates can share a rev
    var rev = 0
    var at = Date()
    var by = ""
    var changes: [String] = []
    var source = Source.manual

    enum Source: String, CaseIterable {
        case sync = "Sync"  // a stored response named this revision
        case likelySync = "Sync?"  // inside a run's window, but no response named it (a comment write)
        case manual = "Manual"
    }
}

/// Marks the revisions of workItem that this app wrote.
/// Exact when a stored ADO response carries the revision number; the comments API answers with the comment
/// instead, so a comment-only revision is only placed by the run's time window. Dry runs wrote nothing.
func attribute(_ revs: [Revision], runs: [Run], workItem: Int) -> [Revision] {
    var written: Set<Int> = []
    var windows: [ClosedRange<Date>] = []
    for run in runs where run.kind != .dryRun {
        guard run.tickets.contains(where: { $0.adoID == workItem }) else { continue }
        windows.append(run.started...run.started.addingTimeInterval(max(run.duration, 0) + 5))
        for call in run.tickets.flatMap(\.calls) {
            guard let o = parseJSON(Data(call.response.utf8)) as? JSONObject,
                  o["id"] as? Int == workItem, let rev = o["rev"] as? Int else { continue }
            written.insert(rev)
        }
    }
    return revs.map { r in
        var r = r
        if written.contains(r.rev) { r.source = .sync } else if windows.contains(where: { $0.contains(r.at) }) { r.source = .likelySync }
        return r
    }
}
