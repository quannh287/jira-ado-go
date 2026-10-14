import Foundation
import SQLite3

/// A thin SQLite connection; values bind and read as Int64, Double, String or nil.
final class Database {
    typealias Statement = (sql: String, args: [Any?])

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// readOnly opens an existing file without changing it, for importing another app's data.
    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw Failure("open database \(path): \(msg)")
        }
        sqlite3_busy_timeout(db, 5000)
        if readOnly { return }
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA journal_mode = WAL")
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    func exec(_ sql: String, _ args: Any?...) throws -> Int { try run(sql, args).changes }

    func query(_ sql: String, _ args: Any?...) throws -> [[Any?]] { try run(sql, args).rows }

    /// Runs every statement or none.
    func transaction(_ stmts: [Statement]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for s in stmts { _ = try run(s.sql, s.args) }
            try exec("COMMIT")
        } catch {
            _ = try? exec("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ args: [Any?]) throws -> (rows: [[Any?]], changes: Int) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw lastError(sql) }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, idx)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as Bool: sqlite3_bind_int64(st, idx, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, Self.transient)
            default: throw Failure("unsupported SQLite value \(String(describing: a))")
            }
        }
        var rows: [[Any?]] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError(sql) }
            rows.append((0..<sqlite3_column_count(st)).map { c -> Any? in
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: return sqlite3_column_int64(st, c)
                case SQLITE_FLOAT: return sqlite3_column_double(st, c)
                case SQLITE_TEXT: return String(cString: sqlite3_column_text(st, c))
                default: return nil
                }
            })
        }
        return (rows, Int(sqlite3_changes(db)))
    }

    private func lastError(_ sql: String) -> Failure {
        let words = sql.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
        return Failure("\(words): \(String(cString: sqlite3_errmsg(db)))")
    }
}
