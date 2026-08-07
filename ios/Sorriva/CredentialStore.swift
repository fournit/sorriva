import Foundation
import Security

// MARK: - CredentialStore protocol
// Abstraction over credential storage — allows test doubles without Keychain.

protocol CredentialStore {
    func set(key: String, username: String, password: String) throws
    func get(key: String) -> (username: String, password: String)?
    func delete(key: String)
}

// MARK: - CredentialKey
//
// Credentials belong to a SERVER, not to a share. They used to be filed under the
// share's sourceId, which meant dropping the last share for a server orphaned its
// credentials under a key nothing could ever look up again: re-adding the server
// minted a fresh UUID, missed, and asked for a password the app already had
// (bNoCredentialReuseOnReAddingServer). Adding a SECOND share to a surviving
// server worked, because a live source row was there to read from — which is why
// the bug looked intermittent.
//
// One credential per server. The UI already models it that way: the server card
// shows a single username. Two accounts on one NAS is not supported, and is not
// worth the complexity until somebody asks for it.

enum CredentialKey {

    /// Stable key for a server. Hosts arrive in several spellings for the same
    /// machine — "AV-Server", "av-server.local", trailing whitespace from a
    /// hand-typed field — and all of them must resolve to one credential.
    static func forHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasSuffix(".local") { h = String(h.dropLast(6)) }
        if h.hasSuffix(".") { h = String(h.dropLast()) }
        return "host:" + h
    }
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

    func set(key: String, username: String, password: String) throws {
        // Encode as "username\0password" — null separator, never valid in either field
        guard let data = "\(username)\0\(password)".data(using: .utf8) else {
            throw CredentialStoreError.encodingFailed
        }

        // Delete any existing item first
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainError(status)
        }
    }

    func get(key: String) -> (username: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key,
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

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Migration helper
    // Called from v12 migration — reads plaintext credentials from a
    // LibrarySource record and moves them to Keychain.
    // Returns the credentialRef (== sourceId) on success, nil if no credentials.

    func migrateFromPlaintext(host: String, username: String?, password: String?) -> String? {
        guard let u = username, !u.isEmpty else { return nil }
        let p = password ?? ""
        let key = CredentialKey.forHost(host)
        do {
            try set(key: key, username: u, password: p)
            return key
        } catch {
            sLog("CREDENTIALS: Migration failed for \(key): \(error)")
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

    /// Resolved SMB credentials, newest storage scheme first.
    ///
    /// Three tiers, deliberately: host key (current), then whatever credentialRef
    /// holds (a share sourceId on rows the v21 migration has not touched), then the
    /// plaintext columns (pre-v12). The fallbacks are cheap and they are the reason
    /// v21 can re-file additively rather than moving entries — a migration that
    /// fails halfway leaves every source still resolvable by its old key instead of
    /// stranding a user with a NAS they can no longer log into.
    var resolvedCredentials: (username: String, password: String) {
        if let creds = KeychainCredentialStore.shared.get(key: CredentialKey.forHost(host)) {
            return creds
        }
        if let ref = credentialRef,
           let creds = KeychainCredentialStore.shared.get(key: ref) {
            return creds
        }
        return (username: username ?? "", password: password ?? "")
    }

    /// Credentials for a server we may have no source row for — the re-add path.
    /// Returns nil when nothing is stored, so callers can tell "no credentials"
    /// apart from "guest".
    static func storedCredentials(forHost host: String) -> (username: String, password: String)? {
        KeychainCredentialStore.shared.get(key: CredentialKey.forHost(host))
    }

    /// Login-ready credentials — resolvedCredentials with the empty-username
    /// guest fallback applied. Every SMB login site should use this rather than
    /// reading the username/password columns, which the v12 migration cleared.
    var loginCredentials: (username: String, password: String) {
        let creds = resolvedCredentials
        return (username: creds.username.isEmpty ? "guest" : creds.username,
                password: creds.password)
    }
}
