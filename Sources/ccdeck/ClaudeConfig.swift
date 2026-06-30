import Foundation

/// Reads and patches `~/.claude.json` — the file Claude Code uses for account
/// *identity* (email, display name, account/org UUIDs), which is separate from
/// the Keychain entry that holds only OAuth tokens.
///
/// `claude auth status` and Claude Code's UI read identity from here, not from
/// the Keychain. So swapping just the token (see `Keychain.activate`) leaves the
/// displayed account stale — it keeps showing whoever last ran `claude auth
/// login`. An account switch must update this file too, or token and identity
/// drift apart. We snapshot the identity block at capture time and write it back
/// on activate.
enum ClaudeConfig {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json")

    /// The identity Claude Code attributes the current login to. Carried as the
    /// raw `oauthAccount` object plus `userID`, written back verbatim — we never
    /// reconstruct individual fields.
    struct Identity {
        var oauthAccount: [String: Any]
        var userID: String?
        var email: String? { oauthAccount["emailAddress"] as? String }
    }

    // MARK: - Snapshot / apply

    /// Snapshot the identity block currently in `~/.claude.json`.
    static func currentIdentity() -> Identity? {
        guard let top = readTop(),
              let oauth = top["oauthAccount"] as? [String: Any] else { return nil }
        return Identity(oauthAccount: oauth, userID: top["userID"] as? String)
    }

    /// Write an account's identity into `~/.claude.json`, preserving every other
    /// key in the file. Atomic (temp file + rename) so a crash can't truncate the
    /// config, and re-applies 0600 perms to match how Claude Code stores it.
    static func applyIdentity(_ identity: Identity) throws {
        var top = readTop() ?? [:]
        top["oauthAccount"] = identity.oauthAccount
        if let uid = identity.userID { top["userID"] = uid }
        let data = try JSONSerialization.data(withJSONObject: top)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    // MARK: - String boundary (for Keychain storage)

    /// JSON-encode the live identity for storage alongside an account's blob.
    static func currentIdentityJSON() -> String? { currentIdentity().flatMap(encode) }

    /// Apply a previously stored identity JSON to `~/.claude.json`.
    static func applyIdentityJSON(_ json: String) throws {
        guard let identity = decode(json) else { throw CocoaError(.coderInvalidValue) }
        try applyIdentity(identity)
    }

    static func encode(_ identity: Identity) -> String? {
        var box: [String: Any] = ["oauthAccount": identity.oauthAccount]
        if let uid = identity.userID { box["userID"] = uid }
        guard let data = try? JSONSerialization.data(withJSONObject: box) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> Identity? {
        guard let data = json.data(using: .utf8),
              let box = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = box["oauthAccount"] as? [String: Any] else { return nil }
        return Identity(oauthAccount: oauth, userID: box["userID"] as? String)
    }

    // MARK: - Helpers

    private static func readTop() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return top
    }
}
