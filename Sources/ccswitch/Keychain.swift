import Foundation
import Security

enum KeychainError: Error { case status(OSStatus) }

/// Generic-password Keychain access.
///
/// Two services are in play:
///   - `officialService` ("Claude Code-credentials"): the live entry Claude Code reads.
///     Activating an account == writing that account's blob here. The account name on
///     this item is the macOS short username (matches what Claude Code writes).
///   - `appService` ("ccswitch"): our private store, one item per managed account,
///     keyed by the account email.
enum Keychain {
    static let officialService = "Claude Code-credentials"
    static let appService = "ccswitch"
    static var officialAccount: String { NSUserName() }

    // MARK: - Primitives

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(service: String, account: String, value: String) throws {
        let data = Data(value.utf8)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - High level

    /// The credential blob Claude Code is currently using.
    static func currentOfficialBlob() -> String? {
        read(service: officialService, account: officialAccount)
    }

    /// Stored blob for a managed account.
    static func storedBlob(email: String) -> String? {
        read(service: appService, account: email)
    }

    static func storeBlob(email: String, blob: String) throws {
        try write(service: appService, account: email, value: blob)
    }

    /// Per-account identity snapshot (the `~/.claude.json` `oauthAccount` block),
    /// stored next to the blob under a suffixed account name. Needed because the
    /// token blob carries no identity, so on switch we restore this into
    /// `~/.claude.json` to keep `claude auth status` in sync. See `ClaudeConfig`.
    private static func identityAccount(_ email: String) -> String { email + "::identity" }

    static func storedIdentity(email: String) -> String? {
        read(service: appService, account: identityAccount(email))
    }

    static func storeIdentity(email: String, json: String) throws {
        try write(service: appService, account: identityAccount(email), value: json)
    }

    static func removeStored(email: String) {
        delete(service: appService, account: email)
        delete(service: appService, account: identityAccount(email))
    }

    /// Activate an account: copy its stored blob into the live Claude Code entry,
    /// verbatim. Only affects sessions launched *after* this point.
    static func activate(email: String) throws {
        guard let blob = storedBlob(email: email) else { throw KeychainError.status(errSecItemNotFound) }
        try write(service: officialService, account: officialAccount, value: blob)
    }
}
