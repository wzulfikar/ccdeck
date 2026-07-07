import Foundation
import Security

enum KeychainError: Error { case status(OSStatus) }

/// Generic-password Keychain access.
///
/// Two services are in play:
///   - `officialService` ("Claude Code-credentials"): the live entry Claude Code reads.
///     Activating an account == writing that account's blob here. The account name on
///     this item is the macOS short username (matches what Claude Code writes).
///   - `appService` ("CC Deck"): our private store, one item per managed account,
///     keyed by the account email.
enum Keychain {
    static let officialService = "Claude Code-credentials"
    /// "CC Deck" in production, "CC Deck (dev)" in the dev variant (bundle id ends
    /// in ".dev") — so running a dev build never touches the real account store.
    /// This string is the service name shown in Keychain Access, so it's spelled
    /// as a product name to sit alongside "Claude Code-credentials".
    /// Note: `officialService` is intentionally NOT isolated; there is only one
    /// live Claude Code credential, and activating accounts is the app's job.
    static let appService: String =
        (Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false) ? "CC Deck (dev)" : "CC Deck"
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

    /// Update an existing generic-password item's data **in place**, preserving its
    /// Keychain ACL (the list of apps trusted to read it without a prompt).
    ///
    /// `SecItemUpdate` rewrites the item's access object as a side effect, dropping
    /// every app but the writer from the trust list — so after a switch `claude`
    /// re-prompts on its next keychain read (the new-chat "allow" dance). The legacy
    /// `SecKeychainItemModifyContent` edits the data of the existing item without
    /// touching its `SecAccess`, so Claude Code's own trust survives and the read
    /// stays silent.
    ///
    /// Login-keychain only by design: the item Claude Code writes lives there, and
    /// only the legacy file-based keychain has a per-app trusted-app ACL. The modern
    /// data-protection keychain gates access by code-signing, not a runtime list, so
    /// there is nothing to preserve — hence the deprecated `SecKeychain*` calls.
    ///
    /// Returns false when no matching item exists (caller falls back to an add, which
    /// necessarily starts a fresh ACL).
    @discardableResult
    static func updatePreservingACL(service: String, account: String, value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
              let item = ref, CFGetTypeID(item) == SecKeychainItemGetTypeID() else { return false }
        // Safe: the type-id check above confirms this is a legacy SecKeychainItem.
        let keychainItem = item as! SecKeychainItem
        let data = Data(value.utf8)
        let status = data.withUnsafeBytes { raw in
            SecKeychainItemModifyContent(keychainItem, nil, UInt32(data.count), raw.baseAddress)
        }
        return status == errSecSuccess
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
        // Preserve the live entry's ACL so Claude Code keeps silent read access — a
        // plain `write` (SecItemUpdate) would reset it and re-prompt on the next read.
        // Fall back to write only when the entry doesn't exist yet (fresh machine,
        // before Claude Code has created it), where there is no ACL to preserve.
        if !updatePreservingACL(service: officialService, account: officialAccount, value: blob) {
            try write(service: officialService, account: officialAccount, value: blob)
        }
    }
}
