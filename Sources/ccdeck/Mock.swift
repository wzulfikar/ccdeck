import Foundation

/// Screenshot/debug stubs, switched on via the `CCDECK_MOCK` env var (comma-separated),
/// so you can capture specific states without waiting for the real situation to occur:
///
///     CCDECK_MOCK=menubar_rate_limited,menubar_70_pct,fake_update
///
/// Each stub is opt-in and inert when unset, so leaving `CCDECK_MOCK` empty (the normal
/// case) changes nothing. Parsed once at launch.
///
/// Stubs:
///  - `fake_update`          — pretend a newer release exists (shows the header update arrow).
///  - `menubar_rate_limited` — force the menu-bar icon to the rate-limited (red, 100%) state.
///  - `menubar_70_pct`       — force the menu-bar icon to 70% usage (orange).
enum Mock {
    /// The set of active stub names parsed from `CCDECK_MOCK`. Empty in normal runs.
    static let active: Set<String> = {
        guard let raw = ProcessInfo.processInfo.environment["CCDECK_MOCK"] else { return [] }
        return Set(raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }()

    static func has(_ name: String) -> Bool { active.contains(name) }

    static var fakeUpdate: Bool { has("fake_update") }
    static var menubarRateLimited: Bool { has("menubar_rate_limited") }
    static var menubar70Pct: Bool { has("menubar_70_pct") }
}
