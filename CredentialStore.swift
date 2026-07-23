import Foundation
import Security

// MARK: - CredentialStore protocol
// Abstraction over credential storage — allows test doubles without Keychain.

protocol CredentialStore {
    func set(sourceId: String, username: String, password: String) throws
    func get(sourceId: String) -> (username: String, password: String)?
    func delete(sourceId: String)
}

// MARK: - SMBCredential

struct SMBCredential {
    let username: String
    let password: String
}

// MARK: - KeychainCredentialStore

final class KeychainCredentialStore: CredentialStore {

    static let shared = KeychainCredentialStore()

    private let service = "app.sorriva.smb"

    private init() {}

    // MARK: - Public API

    func set(sourceId: String, username: String, password: String) throws {
        // Encode as "username\0password" — null separator, never valid in either field
        guard let data = "\(username)\0\(password)".data(using: .utf8) else {
            throw CredentialStoreError.encodingFailed
        }

        // Delete any existing item first
        delete(sourceId: sourceId)

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      sourceId,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainError(status)
        }
    }

    func get(sourceId: String) -> (username: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  sourceId,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }

        let parts = str.components(separatedBy: "\0")
        guard parts.count == 2 else { return nil }
        return (username: parts[0], password: parts[1])
    }

    func delete(sourceId: String) {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  sourceId
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Migration helper
    // Called from v12 migration — reads plaintext credentials from a
    // LibrarySource record and moves them to Keychain.
    // Returns the credentialRef (== sourceId) on success, nil if no credentials.

    func migrateFromPlaintext(sourceId: String, username: String?, password: String?) -> String? {
        guard let u = username, !u.isEmpty else { return nil }
        let p = password ?? ""
        do {
            try set(sourceId: sourceId, username: u, password: p)
            return sourceId
        } catch {
            sLog("CREDENTIALS: Migration failed for \(sourceId): \(error)")
            return nil
        }
    }
}

// MARK: - CredentialStoreError

enum CredentialStoreError: Error, LocalizedError {
    case encodingFailed
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode credentials for Keychain storage."
        case .keychainError(let status):
            return "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }
}

// MARK: - LibrarySource extension
// Convenience accessor that resolves credentials from Keychain.
// Falls back to plaintext fields during migration window.

extension LibrarySource {

    /// Resolved SMB credentials — Keychain first, plaintext fallback during migration.
    var resolvedCredentials: (username: String, password: String) {
        // Keychain — preferred path post-migration
        if let ref = credentialRef,
           let creds = KeychainCredentialStore.shared.get(sourceId: ref) {
            return creds
        }
        // Plaintext fallback — present until v12 migration runs
        return (username: username ?? "", password: password ?? "")
    }
}
