 import Foundation
import Security

enum KeychainError: Error {
    case status(OSStatus)
    /// `/usr/bin/security` exited non-zero. Carries its stderr, which names the real
    /// problem (locked keychain, denied access, bad argument) — without it a failed
    /// switch surfaces as a bare, undiagnosable code.
    case tool(exit: Int32, message: String)
}

extension KeychainError: CustomStringConvertible {
    var description: String {
        switch self {
        case .status(let s): return "status(\(s))"
        case .tool(let code, let message):
            return message.isEmpty ? "security exited \(code)" : "security: \(message)"
        }
    }
}

/// Hex is how the secret is handed to `security add-generic-password -X`; see
/// `SecurityTool.write`.
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

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - The `security` tool

    /// Read/write the *live* Claude Code entry by shelling out to `/usr/bin/security`,
    /// exactly as Claude Code itself does.
    ///
    /// Not a style choice — it is the only way to leave the item's ACL alone.
    /// Every in-process write path rewrites the item's **partition list** to the
    /// calling code's own identity: `SecItemUpdate` does it, and so does the legacy
    /// `SecKeychainItemModifyContent` (which preserves the trusted-app list, so the
    /// damage is invisible in Keychain Access — that UI shows only the app list).
    /// Verified on a scratch item: a partition of `["apple-tool:"]` came back as
    /// `["cdhash:<writer>"]` after a modify.
    ///
    /// Since 10.11 a silent read needs *both* the trusted-app list and the partition
    /// list to admit the caller, so a clobbered partition locks out
    /// `/usr/bin/security` — which is the process Claude Code shells out to on every
    /// credential read. Each live session (Zed agent threads, terminals) then raises
    /// its own "security wants to access key" dialog on its next poll, and they
    /// outlive ccdeck because they belong to the `claude` processes, not to us.
    ///
    /// Letting `security` do the write sidesteps all of it: the partition it stamps is
    /// its own, `apple-tool:`, which is exactly what the entry needs. That also makes
    /// the write self-healing for entries an earlier ccdeck already broke.
    enum SecurityTool {
        static let path = "/usr/bin/security"

        /// `security`'s exit code is the only machine-readable part; its stderr is the
        /// only human-readable one. Both are kept — discarding stderr turns any failure
        /// into an undiagnosable code at the call site.
        private struct Output {
            let code: Int32
            let stdout: String
            let stderr: String
        }

        /// Item-not-found. `security` maps `errSecItemNotFound` onto this exit code,
        /// and it is the one failure that is not an error: it just means no login yet.
        private static let notFound: Int32 = 44

        private static func run(_ args: [String]) throws -> Output {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            // Always give it a stdin: a GUI app's own may be closed, and an inherited
            // closed descriptor makes `security` fail in ways unrelated to the keychain.
            let input = Pipe()
            p.standardInput = input
            do { try p.run() } catch {
                throw KeychainError.tool(exit: -1, message: "could not launch \(path): \(error)")
            }
            try? input.fileHandleForWriting.close()
            // Drain both before waiting: a blob larger than the pipe buffer would deadlock.
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Output(code: p.terminationStatus,
                          stdout: String(decoding: outData, as: UTF8.self),
                          stderr: String(decoding: errData, as: UTF8.self)
                              .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// nil when no such item exists. Throws when the read itself failed, so a locked
        /// or denied keychain is not silently reported as "no login".
        static func read(service: String, account: String) throws -> String? {
            let r = try run(["find-generic-password", "-a", account, "-s", service, "-w"])
            if r.code == notFound { return nil }
            guard r.code == 0 else { throw KeychainError.tool(exit: r.code, message: r.stderr) }
            // `-w` prints the secret and a trailing newline; the blob is JSON, so
            // trimming newlines is lossless.
            return r.stdout.trimmingCharacters(in: .newlines)
        }

        /// Create or replace the item. `-U` updates in place when it already exists,
        /// so an entry Claude Code created keeps its identity and trusted-app list.
        ///
        /// The secret goes on the argument vector as hex, which puts it in this
        /// process's `ps` output for the length of the call. The alternatives are worse:
        /// `security -i` reads stdin through a ~4KB line buffer and chops a longer
        /// command into fragments it then runs as commands of their own (the blob is
        /// ~2KB and grows with every MCP server the user authorises, and hex doubles
        /// it), while `-w` with no value prompts on stdin but truncates at 128 bytes.
        /// The exposure is narrow: anything that can read our `ps` entry runs as this
        /// user and could just as well ask `security` for the credential itself.
        static func write(service: String, account: String, value: String) throws {
            let hex = Data(value.utf8).hexEncodedString()
            let r = try run(["add-generic-password", "-U",
                            "-a", account, "-s", service, "-X", hex])
            guard r.code == 0 else { throw KeychainError.tool(exit: r.code, message: r.stderr) }
        }
    }

    // MARK: - High level

    /// The credential blob Claude Code is currently using.
    ///
    /// Via `SecurityTool` so ccdeck needs no standing in the live entry's ACL — the
    /// item stays exactly as `claude auth login` left it. See `SecurityTool`.
    /// Throws (rather than returning nil) when the read itself failed, so callers can
    /// tell "not logged in" apart from "the keychain would not give it to us".
    static func currentOfficialBlob() throws -> String? {
        try SecurityTool.read(service: officialService, account: officialAccount)
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
        // `security` does the write, not us: an in-process write would stamp the entry's
        // partition list with ccdeck's own identity and lock `/usr/bin/security` out, so
        // every live `claude` session would prompt on its next credential read. See
        // `SecurityTool`. Also covers the fresh-machine case — `-U` adds when absent.
        try SecurityTool.write(service: officialService, account: officialAccount, value: blob)
    }
}
