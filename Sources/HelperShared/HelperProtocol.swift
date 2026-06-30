import Foundation

/// Mach service name the privileged helper publishes and the app connects to.
/// Must match the LaunchDaemon plist's `MachServices` key and `Label`.
public let helperMachServiceName = "com.wzulfikar.ccdeck.helper"

/// Bundle identifier of the main app — the helper only accepts XPC clients whose
/// code signature matches this identifier (and the helper's own signing team,
/// derived at runtime so it works regardless of which identity built the app).
public let appBundleIdentifier = "com.wzulfikar.ccdeck"

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
