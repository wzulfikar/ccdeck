import IOKit.pwr_mgt

/// Holds a system power assertion to keep the Mac awake — the in-process
/// equivalent of `caffeinate -s`. The assertion uses
/// `kIOPMAssertionTypePreventSystemSleep`: it blocks *idle* system sleep on AC
/// and battery. It does NOT block lid-close (clamshell) sleep — no power
/// assertion can; that requires `pmset disablesleep`, run as root by the
/// privileged helper (see `HelperManager`/`ClamshellMonitor`). The display may
/// still sleep. Releasing the assertion (or quitting) restores normal sleep.
final class StayAwake {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    /// Begin keeping the system awake. No-op if already active.
    @discardableResult
    func start(reason: String = "ccdeck keep-awake") -> Bool {
        guard !isActive else { return true }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        isActive = (result == kIOReturnSuccess)
        return isActive
    }

    /// Release the assertion and allow the system to sleep again.
    func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    @discardableResult
    func toggle() -> Bool {
        if isActive { stop() } else { start() }
        return isActive
    }

    deinit { stop() }
}
