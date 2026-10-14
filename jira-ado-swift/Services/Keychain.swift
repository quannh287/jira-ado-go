import Foundation
import Security

/// One secret kept outside the app's files. Calls can block on a Keychain prompt: keep them off the main actor.
nonisolated protocol SecretStore: Sendable {
    /// "" with no error when nothing is stored.
    func get() throws -> String
    func set(_ value: String) throws
    func delete() throws
}

/// The app's secrets: the ADO PAT and the Jira API token.
nonisolated struct Secrets: Sendable {
    var pat: SecretStore
    var jira: SecretStore

    static let keychain = Secrets(pat: Secret.pat, jira: Secret.jiraToken)
    static func memory(pat: String = "", jira: String = "") -> Secrets { Secrets(pat: MemorySecret(pat), jira: MemorySecret(jira)) }
}

/// A secret held only in memory, for tests and UI tests.
nonisolated final class MemorySecret: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ value: String = "") { self.value = value }
    func get() throws -> String { lock.withLock { value } }
    func set(_ v: String) throws { lock.withLock { value = v } }
    func delete() throws { lock.withLock { value = "" } }
}

/// One generic-password item in the macOS Keychain.
nonisolated struct Secret: SecretStore {
    let service: String
    let account: String

    static let pat = Secret(service: "com.example.jiraado", account: "ado-pat")
    static let jiraToken = Secret(service: "com.example.jiraado", account: "jira-api-token")

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func get() throws -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return "" }
        try check(st)
        return (out as? Data).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func set(_ value: String) throws {
        let data = Data(value.utf8)
        let st = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st != errSecItemNotFound { return try check(st) }
        var q = query
        q[kSecValueData as String] = data
        try check(SecItemAdd(q as CFDictionary, nil))
    }

    func delete() throws {
        let st = SecItemDelete(query as CFDictionary)
        if st != errSecItemNotFound { try check(st) }
    }

    private func check(_ st: OSStatus) throws {
        guard st == errSecSuccess else {
            throw Failure(SecCopyErrorMessageString(st, nil) as String? ?? "Keychain error \(st)")
        }
    }
}
