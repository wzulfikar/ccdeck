import Foundation
import Security

enum KeychainError: Error { case status(OSStatus) }

/// Hex is how Keychain ACL entries carry a partition list; see `Keychain.decodePartitions`.
extension Data {
    init?(hexEncoded hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { return nil }
            bytes.append(byte)
            i = next
        }
        self.init(bytes)
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

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
        guard let keychainItem = legacyItem(service: service, account: account) else { return false }
        let data = Data(value.utf8)
        let status = data.withUnsafeBytes { raw in
            SecKeychainItemModifyContent(keychainItem, nil, UInt32(data.count), raw.baseAddress)
        }
        return status == errSecSuccess
    }

    /// The legacy `SecKeychainItem` handle for an item, or nil when it doesn't exist
    /// (or lives in the modern data-protection keychain, which has no editable ACL).
    private static func legacyItem(service: String, account: String) -> SecKeychainItem? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
              let item = ref, CFGetTypeID(item) == SecKeychainItemGetTypeID() else { return nil }
        // Safe: the type-id check above confirms this is a legacy SecKeychainItem.
        return (item as! SecKeychainItem)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Trust (ACL + partition list)

    /// Claude Code does not read the Keychain in-process — it shells out to
    /// `/usr/bin/security find-generic-password -s "Claude Code-credentials"`. So the
    /// principal the ACL has to trust is the `security` tool, and each read is its own
    /// short-lived process: with N sessions live (Zed agent threads, terminals, the
    /// mobile bridge), one untrusted item means N consecutive
    /// "security wants to access key" dialogs, not one.
    static let securityToolPath = "/usr/bin/security"

    /// Since 10.11 the trusted-app list is only half the check — the caller's partition
    /// must also be listed. `/usr/bin/security` is an Apple-signed command-line tool, so
    /// it needs `apple-tool:`, which is exactly what the entry Claude Code creates
    /// already carries. An item created by a *team-signed* app instead gets only
    /// `teamid:<ours>` — that's the state our `SecItemAdd` fallback would leave behind.
    ///
    /// Deliberately minimal: `apple:` (any Apple-signed app) and `teamid:Q6L2SF6YDW`
    /// (Anthropic-signed binaries, for a future in-process read) would both widen who
    /// can read the token silently, and neither is needed today.
    static let requiredPartitions = ["apple-tool:"]

    enum TrustOutcome: Equatable {
        case alreadyTrusted
        case granted
        case failed(OSStatus)
    }

    /// Ensure the live entry trusts `/usr/bin/security` — both in the decrypt ACL entry's
    /// application list and in the partition list — so Claude Code's reads stay silent.
    ///
    /// Repair, not setup. An entry created by `security add-generic-password` (what
    /// `claude auth login` uses) already trusts the tool and carries `apple-tool:`; the
    /// state that breaks it is *us* creating the entry, since `SecItemAdd` from a
    /// team-signed app yields an ACL trusting only ccdeck and partitions `teamid:<ours>`.
    /// Every live session then re-prompts on its next poll, which is why the dialog
    /// arrives ten-deep rather than once.
    ///
    /// Editing an ACL is itself privileged (the ChangeACL entry trusts no app), so a call
    /// that actually changes something raises one keychain-password prompt. That is the
    /// trade: one prompt once, instead of one per live session on every switch.
    ///
    /// Idempotent — returns `.alreadyTrusted` without touching the item, and therefore
    /// without prompting, when nothing is missing.
    @discardableResult
    static func trustSecurityTool(service: String = officialService,
                                  account: String? = nil) -> TrustOutcome {
        guard let item = legacyItem(service: service, account: account ?? officialAccount) else {
            return .failed(errSecItemNotFound)
        }

        var accessRef: SecAccess?
        let accessStatus = SecKeychainItemCopyAccess(item, &accessRef)
        guard accessStatus == errSecSuccess, let access = accessRef else { return .failed(accessStatus) }

        var listRef: CFArray?
        let listStatus = SecAccessCopyACLList(access, &listRef)
        guard listStatus == errSecSuccess, let acls = listRef as? [SecACL] else { return .failed(listStatus) }

        var toolRef: SecTrustedApplication?
        let toolStatus = SecTrustedApplicationCreateFromPath(securityToolPath, &toolRef)
        guard toolStatus == errSecSuccess, let tool = toolRef,
              let toolData = trustedAppData(tool) else { return .failed(toolStatus) }

        var changed = false
        for acl in acls {
            let auths = (SecACLCopyAuthorizations(acl) as? [String]) ?? []
            if auths.contains(kSecACLAuthorizationPartitionID as String) {
                if addRequiredPartitions(to: acl) { changed = true }
            } else if auths.contains(kSecACLAuthorizationDecrypt as String) {
                if trust(tool, data: toolData, in: acl) { changed = true }
            }
        }

        guard changed else { return .alreadyTrusted }
        let setStatus = SecKeychainItemSetAccess(item, access)
        return setStatus == errSecSuccess ? .granted : .failed(setStatus)
    }

    /// Append `tool` to one ACL entry's trusted-app list. Returns false when nothing
    /// changed — already present, unreadable, or an unrestricted entry (a nil app list
    /// means "any application", which already covers us).
    private static func trust(_ tool: SecTrustedApplication, data toolData: Data,
                              in acl: SecACL) -> Bool {
        var appsRef: CFArray?
        var descRef: CFString?
        var prompt = SecKeychainPromptSelector()
        guard SecACLCopyContents(acl, &appsRef, &descRef, &prompt) == errSecSuccess,
              let apps = appsRef as? [SecTrustedApplication] else { return false }
        guard !apps.contains(where: { trustedAppData($0) == toolData }) else { return false }
        let updated = (apps + [tool]) as CFArray
        return SecACLSetContents(acl, updated, descRef ?? "" as CFString, prompt) == errSecSuccess
    }

    /// Merge `requiredPartitions` into the partition ACL entry.
    ///
    /// No entry means partitions aren't enforced on this item at all, so there is
    /// nothing to repair — we never synthesise one (that would only narrow access).
    private static func addRequiredPartitions(to acl: SecACL) -> Bool {
        var appsRef: CFArray?
        var descRef: CFString?
        var prompt = SecKeychainPromptSelector()
        guard SecACLCopyContents(acl, &appsRef, &descRef, &prompt) == errSecSuccess else { return false }

        let current = decodePartitions(descRef as String?)
        let merged = current + requiredPartitions.filter { !current.contains($0) }
        guard merged.count != current.count, let encoded = encodePartitions(merged) else { return false }
        return SecACLSetContents(acl, appsRef, encoded as CFString, prompt) == errSecSuccess
    }

    private static func trustedAppData(_ app: SecTrustedApplication) -> Data? {
        var data: CFData?
        guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess else { return nil }
        return data as Data?
    }

    /// Partition ids out of the partition ACL entry's description.
    ///
    /// The description is not the plist itself — it is the plist's bytes rendered as a
    /// lowercase hex string (verified against the live `Claude Code-credentials` entry,
    /// which decodes to `{Partitions: ["apple-tool:"]}`). Writing raw XML there produces
    /// an entry the Security framework silently ignores, so both hops matter.
    ///
    /// Empty for a nil/absent/non-hex/malformed description; callers treat that as
    /// "nothing to merge into" and leave the entry alone.
    static func decodePartitions(_ description: String?) -> [String] {
        guard let hex = description, let data = Data(hexEncoded: hex),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let partitions = dict["Partitions"] as? [String] else { return [] }
        return partitions
    }

    static func encodePartitions(_ partitions: [String]) -> String? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: ["Partitions": partitions],
                                                             format: .xml, options: 0) else { return nil }
        return data.hexEncodedString()
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
        // Cheap and silent when the trust is already intact (the common path, since
        // `updatePreservingACL` keeps it). It earns its keep after the `write` fallback
        // above, which leaves an entry only ccdeck can read.
        trustSecurityTool()
    }
}
