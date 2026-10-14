import Foundation
import os

/// The diagnostic log: ~/Library/Logs/jira-ado.log (inside the sandbox container) plus the unified log.
/// Callers log URLs, IDs and statuses — never request bodies, headers, PATs or tokens.
nonisolated enum AppLog {
    static let fileName = "jira-ado.log"
    private static let maxSize = 10 << 20  // rotated to .1 at launch past this
    private static let os = Logger(subsystem: "com.example.jiraado", category: "app")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private(set) static var path = ""

    /// Opens the log file; failures leave only the unified log.
    static func setup() {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Logs") else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(fileName)
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > maxSize {
            try? fm.removeItem(atPath: file.path + ".1")
            try? fm.moveItem(atPath: file.path, toPath: file.path + ".1")
        }
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        h.seekToEndOfFile()
        lock.withLock { handle = h; path = file.path }
    }

    static func info(_ msg: String, _ attrs: KeyValuePairs<String, Any> = [:]) { write("INFO", msg, attrs) }
    static func warn(_ msg: String, _ attrs: KeyValuePairs<String, Any> = [:]) { write("WARN", msg, attrs) }
    static func error(_ msg: String, _ attrs: KeyValuePairs<String, Any> = [:]) { write("ERROR", msg, attrs) }

    private static func write(_ level: String, _ msg: String, _ attrs: KeyValuePairs<String, Any>) {
        let kv = attrs.map { "\($0.key)=\(quote("\($0.value)"))" }.joined(separator: " ")
        let line = "level=\(level) msg=\(quote(msg))" + (kv.isEmpty ? "" : " " + kv)
        os.log("\(line, privacy: .public)")
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        lock.withLock { handle?.write(Data("time=\(stamp) \(line)\n".utf8)) }
    }

    private static func quote(_ s: String) -> String {
        s.contains(where: { $0 == " " || $0 == "\"" || $0 == "=" }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\"" : s
    }
}
