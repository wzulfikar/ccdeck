import Foundation
import Security
import HelperShared

/// Accepts incoming XPC connections, but only from our own signed app.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ConnectionValidator.isValid(connection) else {
            NSLog("ccdeck-helper: rejected unverified XPC client (pid \(connection.processIdentifier))")
            return false
        }
        let service = HelperService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = service
        // If the app quits or crashes while sleep is suppressed, don't strand the
        // system with disablesleep=1 — undo it as soon as the client goes away.
        connection.invalidationHandler = { [weak service] in service?.restoreOnDisconnect() }
        connection.interruptionHandler = { [weak service] in service?.restoreOnDisconnect() }
        connection.resume()
        return true
    }
}

/// The exported object, one per connection. Runs `pmset` as root.
final class HelperService: NSObject, HelperProtocol {
    private weak var connection: NSXPCConnection?
    /// Did *this* connection turn suppression on? Used to revert on disconnect.
    private var suppressedByUs = false

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func setDisableSleep(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        let (ok, err) = Self.runPmset(disable: disabled)
        if ok { suppressedByUs = disabled }
        reply(ok, err)
    }

    func getDisableSleep(withReply reply: @escaping (Bool) -> Void) {
        reply(Self.currentDisableSleep())
    }

    func restoreOnDisconnect() {
        guard suppressedByUs else { return }
        _ = Self.runPmset(disable: false)
        suppressedByUs = false
    }

    // MARK: - pmset

    /// `pmset -a disablesleep 0|1`. Applies to every power profile so lid-close
    /// sleep is suppressed on battery as well as AC.
    @discardableResult
    private static func runPmset(disable: Bool) -> (Bool, String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-a", "disablesleep", disable ? "1" : "0"]
        let errPipe = Pipe()
        p.standardError = errPipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        if p.terminationStatus == 0 { return (true, nil) }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, (msg?.isEmpty == false ? msg : "pmset exited \(p.terminationStatus)"))
    }

    /// Best-effort: scan `pmset -g` for the `SleepDisabled` flag.
    private static func currentDisableSleep() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.contains("1")
        }
        return false
    }
}

/// Verifies an XPC peer is our own app: our bundle id, chaining to Apple, and —
/// when the helper itself carries a team id — signed by that same team. The team
/// is read from the helper's own signature at runtime rather than hardcoded, so
/// the check follows whatever identity built the app (personal Apple Development
/// vs. a Developer ID) without needing a code change. Note: PID-based
/// identification carries a small TOCTOU window; acceptable here since the action
/// is a benign system setting and the signature requirement still gates it.
enum ConnectionValidator {
    static func isValid(_ connection: NSXPCConnection) -> Bool {
        guard let req = clientRequirement() else { return false }

        let attrs = [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else { return false }

        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    private static func clientRequirement() -> SecRequirement? {
        var text = "anchor apple generic and identifier \"\(appBundleIdentifier)\""
        if let team = ownTeamIdentifier() {
            text += " and certificate leaf[subject.OU] = \"\(team)\""
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess else { return nil }
        return req
    }

    /// The helper's own Team Identifier, or nil if signed without one (e.g. ad-hoc).
    private static func ownTeamIdentifier() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
