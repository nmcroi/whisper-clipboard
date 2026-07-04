import Foundation
import Security

/// Thin wrapper over the Security framework for storing secrets (the Claude API
/// key, the PLAUD credentials) as generic passwords. Secrets are stored **only**
/// in the login keychain — they never touch UserDefaults or any file on disk.
///
/// Access is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable after
/// the first unlock following boot, never migrated to another device.
///
/// ## Two shapes of API
/// - The **static** members (`save/read/delete/hasKey`) operate on the Claude
///   API key (account ``account``). They are kept as-is for source compatibility
///   with existing call sites and tests.
/// - The **instance** members operate on an arbitrary account under the same
///   service, so a second secret (e.g. PLAUD, account ``plaudAccount``) lives
///   alongside the API key without any of the logic being duplicated. The static
///   members are implemented in terms of an instance for `account`.
public struct KeychainStore: Sendable {

    /// Errors surfaced by the wrapper, carrying the underlying `OSStatus` for
    /// diagnostics.
    public enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    public static let service = "nl.nielscroiset.whisperclipboard"
    /// Account for the Claude API key (unchanged).
    public static let account = "anthropic-api-key"
    /// Account for the PLAUD credentials blob (email + password/token as JSON).
    public static let plaudAccount = "plaud-credentials"

    /// The keychain account this instance reads/writes.
    public let account: String

    public init(account: String) {
        self.account = account
    }

    /// A store for the PLAUD credentials item.
    public static let plaud = KeychainStore(account: plaudAccount)

    // MARK: - Instance API (arbitrary account)

    /// Saves (or replaces) `value` for this account. An empty/blank value deletes
    /// the entry instead of storing whitespace.
    public func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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
            kSecAttrService as String: Self.service,
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

    /// Reads the stored value for this account, or `nil` if none is set.
    public func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
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

    /// Deletes the stored value for this account (no-op if none exists).
    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Convenience: whether a non-empty value is currently stored for this account.
    public func hasValue() -> Bool {
        (try? read())?.isEmpty == false
    }

    // MARK: - Static API (Claude API key — unchanged surface)

    private static let apiKeyStore = KeychainStore(account: account)

    /// Saves (or replaces) the Claude API key. Blank deletes.
    public static func save(_ key: String) throws { try apiKeyStore.save(key) }

    /// Reads the stored API key, or `nil` if none is set.
    public static func read() throws -> String? { try apiKeyStore.read() }

    /// Deletes the stored key (no-op if none exists).
    public static func delete() throws { try apiKeyStore.delete() }

    /// Convenience: whether a non-empty key is currently stored.
    public static func hasKey() -> Bool { apiKeyStore.hasValue() }
}

// MARK: - PLAUD credentials

/// The PLAUD login secret, stored as one JSON blob in the Keychain under
/// ``KeychainStore/plaudAccount``. The email is *also* mirrored into
/// `AppSettings.plaudEmail` for display, but the password/token live **only**
/// here. When `token` is present it is used directly as the bearer (the
/// paste-a-token fallback); otherwise `password` drives an email+password login.
public struct PlaudCredentials: Codable, Equatable, Sendable {
    public var email: String
    /// PLAUD account password (empty when using a pasted token instead).
    public var password: String
    /// A raw bearer token pasted by the user (empty when using email+password).
    public var token: String

    public init(email: String = "", password: String = "", token: String = "") {
        self.email = email
        self.password = password
        self.token = token
    }

    /// True when there is *something* to authenticate with.
    public var isConfigured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: Keychain round-trip

    /// Loads the stored credentials, or `nil` when none are saved / unreadable.
    public static func load(from store: KeychainStore = .plaud) -> PlaudCredentials? {
        guard let json = try? store.read(), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlaudCredentials.self, from: data)
    }

    /// Persists these credentials. Deletes the Keychain item when there is no
    /// actual secret left to store (password **and** token both empty) — an
    /// email-only blob is useless (you can't authenticate with it), and the email
    /// is already mirrored into `AppSettings.plaudEmail` for display. So clearing
    /// the password removes the item rather than leaving a dangling secret.
    public func save(to store: KeychainStore = .plaud) throws {
        let hasSecret = !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSecret else {
            try store.delete()
            return
        }
        let data = try JSONEncoder().encode(self)
        try store.save(String(decoding: data, as: UTF8.self))
    }
}
