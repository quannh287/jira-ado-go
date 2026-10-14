import Foundation

enum Outcome: String, Codable, CaseIterable { case created, updated, skipped, failed }

struct APICall: Codable, Hashable {
    var method = ""
    var url = ""
    var request = ""  // JSON body sent to ADO
    var status = 0
    var response = ""
    var retries = 0
    var duration: TimeInterval = 0
    var error = ""
}

struct Ticket: Codable, Hashable {
    var key = ""
    var summary = ""
    var parentKey = ""  // Jira parent of a sub-task, for grouping the report
    var outcome = Outcome.skipped
    var workItemType = ""
    var adoID = 0
    var message = ""  // what happened, e.g. why it was skipped
    var error = ""  // only when outcome is failed
    var calls: [APICall] = []
}

enum RunStatus: String, Codable, CaseIterable { case success, partial, failed }

enum RunKind: String, Codable { case sync = "", dryRun = "dry-run", retry = "retry" }

struct Run: Identifiable, Codable, Hashable {
    var id = 0
    var jobID = 0
    var started = Date()
    var duration: TimeInterval = 0
    var since = ""  // cursor the run started from; "" = full backlog
    var error = ""  // the run itself failed (auth, Jira search…)
    var kind = RunKind.sync
    var tickets: [Ticket] = []

    var failedKeys: [String] { tickets.filter { $0.outcome == .failed && !$0.key.isEmpty }.map(\.key) }

    func count(_ o: Outcome) -> Int { tickets.reduce(0) { $0 + ($1.outcome == o ? 1 : 0) } }

    /// The run failing is failed, any failed ticket is partial.
    var status: RunStatus { !error.isEmpty ? .failed : count(.failed) > 0 ? .partial : .success }
}

struct RunOptions {
    var dryRun = false
    /// Limits the run to these Jira issues (Retry failed); the cursor is neither read nor moved.
    var keys: [String] = []
    var onProgress: ((SyncProgress) -> Void)?
}

struct SyncProgress {
    var run: Run
    var done = 0
    var total = 0  // 0 while still searching Jira
}
