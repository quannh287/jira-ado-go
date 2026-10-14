import Foundation

/// What Jira and ADO accept as mapping values; empty lists mean "type it yourself".
struct Catalog {
    var jiraTypes: [String] = [], jiraStatuses: [String] = [], jiraPriorities: [String] = []
    var adoTypes: [String] = []
    var adoStates: [String: [String]] = [:]

    func statesFor(_ types: [String]) -> [String] { union(types.map { adoStates[$0] ?? [] }) }
}

/// Merges lists without duplicates (case-insensitive), keeping first-seen order.
func union(_ lists: [[String]]) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for s in lists.joined() {
        let k = s.trimmingCharacters(in: .whitespaces).lowercased()
        if !k.isEmpty, seen.insert(k).inserted { out.append(s) }
    }
    return out
}
