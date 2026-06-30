import Foundation
import ServiceManagement
import HelperShared

enum HelperError: LocalizedError {
    case needsApproval
    case noConnection
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .needsApproval: return "approval required in System Settings ▸ Login Items"
        case .noConnection:  return "couldn't reach the helper"
        case .helper(let m): return m
        }
    }
}

/// Registers and talks to the privileged `pmset` helper over XPC. The helper does
/// the lid-close-on-battery part (`pmset disablesleep`); the in-process power
/// assertion in `StayAwake` covers ordinary idle sleep.
///
/// Deliberately NOT `@MainActor`: XPC invokes the reply / error blocks on its own
/// dispatch queue, so the continuation closures must be non-isolated — making them
/// actor-isolated triggers a Swift isolation assertion (SIGTRAP) when XPC calls
/// back off the main thread. The only shared mutable state (`connection`) is
/// guarded by a lock instead.
final class HelperManager: @unchecked Sendable {
    static let shared = HelperManager()

    /// Filename of the LaunchDaemon plist embedded at
    /// `Contents/Library/LaunchDaemons/` by the build script.
    private let plistName = "\(helperMachServiceName).plist"
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private var service: SMAppService { .daemon(plistName: plistName) }

    /// Ensure the daemon is registered. First time, macOS parks it in
    /// `.requiresApproval` and we bounce the user to Login Items.
    func ensureRegistered() throws {
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw HelperError.needsApproval
        default:
            try service.register()
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw HelperError.needsApproval
            }
        }
    }

    /// Tear the helper down completely: unregister the daemon and drop the XPC link.
    func unregister() {
        try? service.unregister()
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.invalidationHandler = { [weak self] in self?.clearConnection() }
        c.interruptionHandler = { [weak self] in self?.clearConnection() }
        c.resume()
        connection = c
        return c
    }

    private func clearConnection() {
        lock.lock()
        connection = nil
        lock.unlock()
    }

    func setDisableSleep(_ on: Bool) async throws {
        try ensureRegistered()
        let conn = currentConnection()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // These closures run on XPC's queue — must stay non-isolated.
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: error)
            }) as? HelperProtocol else {
                cont.resume(throwing: HelperError.noConnection)
                return
            }
            proxy.setDisableSleep(on) { ok, err in
                if ok { cont.resume() }
                else { cont.resume(throwing: HelperError.helper(err ?? "unknown error")) }
            }
        }
    }
}
