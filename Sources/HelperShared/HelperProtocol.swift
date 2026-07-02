import Foundation

/// Suffix the helper's id carries over the app's (`<app id>.helper`).
private let helperSuffix = ".helper"
/// Used only if `Bundle.main.bundleIdentifier` is somehow unavailable.
private let fallbackAppIdentifier = "com.wzulfikar.ccdeck"

/// Bundle identifier of the main app — the helper only accepts XPC clients whose
/// code signature matches this identifier (and the helper's own signing team,
/// derived at runtime so it works regardless of which identity built the app).
///
/// Derived at runtime from `Bundle.main` so a single source tree builds either
/// variant (dev = `com.wzulfikar.ccdeck-dev`, prod = `com.wzulfikar.ccdeck`) with
/// no code edits. The same logic runs correctly in both processes because
/// `Bundle.main` differs per process: in the app it's the app's id (no `.helper`
/// suffix); in the helper it's the helper's own embedded id (which ends in
/// `.helper`), so we strip the suffix to recover the app id it must trust.
public let appBundleIdentifier: String = {
    let id = Bundle.main.bundleIdentifier ?? fallbackAppIdentifier
    return id.hasSuffix(helperSuffix) ? String(id.dropLast(helperSuffix.count)) : id
}()

/// Mach service name the privileged helper publishes and the app connects to.
/// Must match the LaunchDaemon plist's `MachServices` key and `Label`.
public let helperMachServiceName = appBundleIdentifier + helperSuffix

/// XPC contract between the app (client) and the root helper (server).
/// Kept tiny on purpose: the only privileged action is flipping `pmset
/// disablesleep`, which is what actually keeps the Mac awake with the lid closed
/// on battery (power assertions can't do that).
@objc public protocol HelperProtocol {
    /// Enable (`true`) or disable (`false`) system sleep suppression.
    /// `reply(ok, errorMessage)` — `ok == false` carries a human-readable reason.
    func setDisableSleep(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)

    /// Best-effort read of the current `disablesleep` state.
    func getDisableSleep(withReply reply: @escaping (Bool) -> Void)
}
