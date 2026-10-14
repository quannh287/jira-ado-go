import Foundation

/// Links a Jira comment to the ADO comment it was copied to.
struct CommentMapping: Hashable {
    var workItemID: Int
    var jiraCommentID: String
    var adoCommentID: Int
    var jiraUpdated: String
}

/// What a sync persists while it runs.
protocol SyncState {
    func cursor(job: Int) throws -> String  // "" = never synced
    func setCursor(job: Int, _ iso: String) throws
    func commentMappings(workItem: Int) throws -> [String: CommentMapping]
    func saveCommentMapping(_ m: CommentMapping) throws
}
