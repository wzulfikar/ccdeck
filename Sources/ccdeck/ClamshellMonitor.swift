import Foundation
import IOKit

/// Watches the laptop lid (clamshell) state via IOKit and fires `onLidClosed`
/// each time the lid shuts.
///
/// Used by keep-awake: the `StayAwake` assertion (`PreventSystemSleep`) keeps the
/// machine running but deliberately *allows* the display to sleep, and the
/// privileged `pmset disablesleep` stops clamshell sleep — so with the lid down
/// the Mac keeps working while the internal panel stays powered. Sleeping the
/// display on lid-close turns that panel off without affecting anything else.
///
/// Only listens while keep-awake is active, so a fired callback unconditionally
/// means "lid just closed, sleep the display now."
final class ClamshellMonitor {
    var onLidClosed: (() -> Void)?

    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var rootDomain: io_service_t = 0
    private var lastClosed = false

    /// Begin watching. No-op if already running.
    func start() {
        guard port == nil else { return }
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0, let p = IONotificationPortCreate(kIOMainPortDefault) else {
            if rootDomain != 0 { IOObjectRelease(rootDomain); rootDomain = 0 }
            return
        }
        port = p
        // Deliver callbacks on the main queue; we only shell out from them.
        IONotificationPortSetDispatchQueue(p, DispatchQueue.main)

        lastClosed = Self.lidClosed(rootDomain)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        // IOPMrootDomain emits a general-interest message on power events including
        // clamshell changes. Rather than decode the exact message, just re-read the
        // state on every notification and act on the open→closed transition.
        IOServiceAddInterestNotification(p, rootDomain, kIOGeneralInterest, { refcon, _, _, _ in
            guard let refcon else { return }
            Unmanaged<ClamshellMonitor>.fromOpaque(refcon).takeUnretainedValue().evaluate()
        }, ctx, &notification)
    }

    /// Stop watching and release the IOKit resources.
    func stop() {
        if notification != 0 { IOObjectRelease(notification); notification = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        if rootDomain != 0 { IOObjectRelease(rootDomain); rootDomain = 0 }
        lastClosed = false
    }

    private func evaluate() {
        let closed = Self.lidClosed(rootDomain)
        defer { lastClosed = closed }
        if closed && !lastClosed { onLidClosed?() }
    }

    private static func lidClosed(_ rootDomain: io_service_t) -> Bool {
        guard let cf = IORegistryEntryCreateCFProperty(rootDomain,
                "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return false }
        return (cf as? Bool) ?? false
    }

    deinit { stop() }
}

/// Thin wrapper over `pmset displaysleepnow` — sleeps the display immediately
/// without sleeping the system. Runs as the regular user (no privileges).
enum DisplayControl {
    static func sleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}
