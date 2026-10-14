import Foundation

/// A failure carrying a message for the report, like Go's errors.New.
nonisolated struct Failure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated func describe(_ error: Error) -> String {
    if error is CancellationError { return "Cancelled" }
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return "\(error)"
}
