import Foundation
import HelperShared

// Privileged root helper. Launched on demand by launchd when the app connects to
// the mach service, and exits when idle. Its only job is to run `pmset
// disablesleep` on the app's behalf — the one knob that keeps the Mac awake with
// the lid closed on battery, which power assertions (caffeinate) cannot do.

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
