import Foundation
import Security

/// Thin wrapper over the Security framework for storing the Claude API key as a
/// generic password. The key is stored **only** in the login keychain — it never
/// touches UserDefaults or any file on disk.
///
/// Access is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable after
/// the first unlock following boot, never migrated to another device.
enum KeychainStore {

    /// Errors surfaced by the wrapper, carrying the underlying `OSStatus` for
    /// diagnostics.
    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    static let service = "nl.nielscroiset.whisperclipboard"
    static let account = "anthropic-api-key"

    /// Saves (or replaces) the API key. An empty/blank value deletes the entry
    /// instead of storing whitespace.
    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete()
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }

        // Try updating an existing item first; fall back to adding.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }
        throw KeychainError.unexpectedStatus(updateStatus)
    }

    /// Reads the stored API key, or `nil` if none is set.
    static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Deletes the stored key (no-op if none exists).
    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Convenience: whether a non-empty key is currently stored.
    static func hasKey() -> Bool {
        (try? read())?.isEmpty == false
    }
}
