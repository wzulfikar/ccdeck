import AppKit

/// Pure, unit-testable presentation logic for the menu-bar item — the single source of
/// truth for its color and gauge glyph. `AppModel` feeds it live state and `AppDelegate`
/// renders the result; keeping the decisions here (free of AppKit rendering, SQLite, and
/// the Keychain) means they can be exercised directly in tests.
///
/// Spec: `docs/menubar-states.md`. `pct` is always the active account's *worst window*
/// (max of the 5-hour and 7-day percentages), or nil when usage is unknown.
enum MenuBarStyle {
    // Concrete sRGB, not dynamic `.systemX`: these get baked into the icon pixels, and a
    // catalog color resolves against the status button's (lying `.aqua`) appearance and
    // comes out dark-on-dark. Approximations of the matching system colors.
    static let orange = NSColor(srgbRed: 1.0, green: 0.584, blue: 0.0, alpha: 1)     // ~systemOrange
    static let red    = NSColor(srgbRed: 1.0, green: 0.231, blue: 0.188, alpha: 1)   // ~systemRed
    static let purple = NSColor(srgbRed: 0.686, green: 0.322, blue: 0.871, alpha: 1) // ~systemPurple

    /// Icon + text color (they share one color), keyed on usage. Stay-awake is a distinct
    /// "mode" signal that overrides the usage color. nil = leave the image as a template so
    /// the bar auto-recolors it (black in light mode, white in dark) — the safe < 70% state.
    static func color(pct: Double?, stayAwake: Bool) -> NSColor? {
        if stayAwake { return purple }        // mode override — wins over any usage color
        guard let pct else { return nil }
        if pct >= 100 { return red }
        if pct >= 70 { return orange }
        return nil
    }

    /// SF Symbol gauge name. With the % text shown the gauge is decorative (static 50%,
    /// the number carries the meaning); with it hidden the needle tracks usage, bucketed
    /// into the variants Apple ships. Unknown usage falls back to 50%.
    ///
    /// Buckets (usage → gauge): 0–10 → 0, 11–40 → 33, 41–50 → 50, 51–80 → 67, 81–100 → 100.
    /// (Apple ships `67percent`, not 66 — the "two-thirds" glyph.)
    ///
    /// While the first fetch is still in flight (`isLoading`, no usage yet) the needle sits
    /// at 0 — an empty gauge the caller pulses to signal "loading". Unknown-and-not-loading
    /// (a failed/idle fetch) keeps the neutral 50% glyph.
    static func gaugeSymbol(pct: Double?, showUsage: Bool, isLoading: Bool = false) -> String {
        if showUsage { return gaugeName(50) }
        guard let pct else { return gaugeName(isLoading ? 0 : 50) }
        switch pct {
        case ..<11:  return gaugeName(0)
        case ..<41:  return gaugeName(33)
        case ..<51:  return gaugeName(50)
        case ..<81:  return gaugeName(67)
        default:     return gaugeName(100)
        }
    }

    /// Menu-bar countdown label: minutes until a reset, but only when it's within the
    /// 5-minute window that promotes it into the text slot. nil otherwise. Rounds up, with
    /// a floor of 1 so it never shows "0 min" while a reset is still pending.
    static func resetCountdownMinutes(secondsUntilReset secs: TimeInterval) -> Int? {
        guard secs > 0 && secs <= 5 * 60 else { return nil }
        return max(1, Int(ceil(secs / 60)))
    }

    /// The full menu-bar presentation, composed the way `AppModel` wires it — the single
    /// source of truth for that split, so it can be tested without spinning up the model:
    ///
    /// - **title + gauge** key on the **5-hour** window (the live burn rate), so the number
    ///   and needle always reflect the current 5-hour usage.
    /// - **color** keys on the **worst** window (max of 5-hour and 7-day), so red is a hard
    ///   stop triggered by *either* limit and orange warns on whichever binds first.
    ///
    /// The imminent-reset countdown (handled by the caller) may still replace `title`.
    static func presentation(fiveHourPct: Double?, sevenDayPct: Double?,
                             showUsage: Bool, stayAwake: Bool,
                             isLoading: Bool = false) -> Presentation {
        let worst = [fiveHourPct, sevenDayPct].compactMap { $0 }.max()
        return Presentation(
            title: fiveHourPct.map { "\(Int($0))%" } ?? "—",
            gaugeSymbol: gaugeSymbol(pct: fiveHourPct, showUsage: showUsage, isLoading: isLoading),
            color: color(pct: worst, stayAwake: stayAwake)
        )
    }

    struct Presentation: Equatable {
        var title: String
        var gaugeSymbol: String
        var color: NSColor?
    }

    private static func gaugeName(_ percent: Int) -> String {
        "gauge.with.dots.needle.\(percent)percent"
    }
}
