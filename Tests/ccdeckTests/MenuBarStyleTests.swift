import Testing
import AppKit
@testable import ccdeck

/// Verifies the menu-bar presentation logic against `docs/menubar-states.md`.
@Suite("MenuBarStyle")
struct MenuBarStyleTests {

    // MARK: - Color states (docs/menubar-states.md ▸ "Color states")

    @Test("< 70% usage → normal (nil, so the bar auto-recolors black/white)",
          arguments: [0.0, 1.0, 50.0, 69.0, 69.999])
    func normalBelow70(pct: Double) {
        #expect(MenuBarStyle.color(pct: pct, stayAwake: false) == nil)
    }

    @Test("70–99% usage → orange", arguments: [70.0, 70.001, 85.0, 99.0, 99.999])
    func orange70to99(pct: Double) {
        #expect(MenuBarStyle.color(pct: pct, stayAwake: false) == MenuBarStyle.orange)
    }

    @Test("100% usage → red", arguments: [100.0, 100.001, 150.0])
    func redAt100(pct: Double) {
        #expect(MenuBarStyle.color(pct: pct, stayAwake: false) == MenuBarStyle.red)
    }

    @Test("Unknown usage → normal (nil)")
    func unknownUsageIsNormal() {
        #expect(MenuBarStyle.color(pct: nil, stayAwake: false) == nil)
    }

    // "When Stay awake is on, the icon and text are purple, overriding the usage color."
    @Test("Stay awake → purple, overriding any usage level",
          arguments: [nil, 0.0, 69.0, 85.0, 100.0] as [Double?])
    func stayAwakePurpleOverride(pct: Double?) {
        #expect(MenuBarStyle.color(pct: pct, stayAwake: true) == MenuBarStyle.purple)
    }

    @Test("The three usage colors are distinct")
    func colorsAreDistinct() {
        let set = Set([MenuBarStyle.orange, MenuBarStyle.red, MenuBarStyle.purple])
        #expect(set.count == 3)
    }

    // MARK: - Gauge symbol (docs/menubar-states.md ▸ "Show usage % in menu bar")

    @Test("Show % ON → gauge is static at 50%, regardless of usage",
          arguments: [nil, 0.0, 33.0, 84.0, 100.0] as [Double?])
    func gaugeStaticWhenShowingPercent(pct: Double?) {
        #expect(MenuBarStyle.gaugeSymbol(pct: pct, showUsage: true)
                == "gauge.with.dots.needle.50percent")
    }

    @Test("Show % OFF → needle bucketed by usage range")
    func gaugeTracksUsageWhenHidden() {
        // (usage, expected gauge variant) — buckets: 0–10→0, 11–40→33, 41–50→50,
        // 51–80→67, 81–100→100. Includes both ends of every bucket.
        let cases: [(Double, Int)] = [
            (0, 0), (10, 0),          // 0–10 → 0
            (11, 33), (12, 33), (40, 33),   // 11–40 → 33  (the 12% account belongs here)
            (41, 50), (44, 50), (50, 50),   // 41–50 → 50
            (51, 67), (80, 67),       // 51–80 → 67
            (81, 100), (100, 100),    // 81–100 → 100
        ]
        for (usage, variant) in cases {
            #expect(MenuBarStyle.gaugeSymbol(pct: usage, showUsage: false)
                    == "gauge.with.dots.needle.\(variant)percent",
                    "usage \(usage)% should map to the \(variant)% gauge")
        }
    }

    @Test("Show % OFF, unknown usage (not loading) → falls back to the 50% glyph")
    func gaugeFallsBackWhenUnknown() {
        #expect(MenuBarStyle.gaugeSymbol(pct: nil, showUsage: false)
                == "gauge.with.dots.needle.50percent")
    }

    @Test("First-load (loading, no data yet) → empty 0% gauge to pulse")
    func gaugeEmptyWhileLoading() {
        #expect(MenuBarStyle.gaugeSymbol(pct: nil, showUsage: false, isLoading: true)
                == "gauge.with.dots.needle.0percent")
    }

    @Test("Loading is ignored once real usage has arrived")
    func loadingIgnoredOnceUsageKnown() {
        #expect(MenuBarStyle.gaugeSymbol(pct: 84, showUsage: false, isLoading: true)
                == "gauge.with.dots.needle.100percent")
    }

    @Test("Show % OFF → usage is clamped to 0–100 before snapping")
    func gaugeClampsOutOfRange() {
        #expect(MenuBarStyle.gaugeSymbol(pct: -20, showUsage: false)
                == "gauge.with.dots.needle.0percent")
        #expect(MenuBarStyle.gaugeSymbol(pct: 250, showUsage: false)
                == "gauge.with.dots.needle.100percent")
    }

    // MARK: - Composed presentation (title + gauge = 5-hour; color = worst window)

    @Test("Title and gauge always follow the 5-hour window, never the 7-day")
    func titleAndGaugeTrackFiveHour() {
        // Sam's screenshot: 5-hour 16%, 7-day 64%. Number shows 16% (not 64%),
        // gauge maps 16% → 33% bucket, and 64% worst window is still < 70% so color is normal.
        let p = MenuBarStyle.presentation(fiveHourPct: 16, sevenDayPct: 64,
                                          showUsage: false, stayAwake: false)
        #expect(p.title == "16%")
        #expect(p.gaugeSymbol == "gauge.with.dots.needle.33percent")
        #expect(p.color == nil)
    }

    @Test("7-day exhausted → red hard stop, but title/gauge stay on the 5-hour burn")
    func sevenDayExhaustedIsRedButFiveHourDrivesReadout() {
        // 5-hour only 16%, but the 7-day window is maxed → red (hard stop from either
        // window). The number and gauge still reflect the live 16% 5-hour usage.
        let p = MenuBarStyle.presentation(fiveHourPct: 16, sevenDayPct: 100,
                                          showUsage: false, stayAwake: false)
        #expect(p.title == "16%")
        #expect(p.gaugeSymbol == "gauge.with.dots.needle.33percent")
        #expect(p.color == MenuBarStyle.red)
    }

    @Test("5-hour exhausted → red as well (hard stop from the 5-hour window)")
    func fiveHourExhaustedIsRed() {
        let p = MenuBarStyle.presentation(fiveHourPct: 100, sevenDayPct: 20,
                                          showUsage: false, stayAwake: false)
        #expect(p.title == "100%")
        #expect(p.gaugeSymbol == "gauge.with.dots.needle.100percent")
        #expect(p.color == MenuBarStyle.red)
    }

    @Test("7-day in warning band → orange, title/gauge still on 5-hour")
    func sevenDayWarnIsOrange() {
        let p = MenuBarStyle.presentation(fiveHourPct: 30, sevenDayPct: 85,
                                          showUsage: false, stayAwake: false)
        #expect(p.title == "30%")
        #expect(p.gaugeSymbol == "gauge.with.dots.needle.33percent")
        #expect(p.color == MenuBarStyle.orange)
    }

    @Test("Show % ON → gauge static 50%, title carries the 5-hour number")
    func presentationWithPercentShown() {
        let p = MenuBarStyle.presentation(fiveHourPct: 16, sevenDayPct: 64,
                                          showUsage: true, stayAwake: false)
        #expect(p.title == "16%")
        #expect(p.gaugeSymbol == "gauge.with.dots.needle.50percent")
    }

    @Test("Stay awake → purple, overriding even a 7-day hard stop")
    func presentationStayAwakeOverridesRed() {
        let p = MenuBarStyle.presentation(fiveHourPct: 16, sevenDayPct: 100,
                                          showUsage: false, stayAwake: true)
        #expect(p.color == MenuBarStyle.purple)
    }

    @Test("Unknown usage → dash title, fallback gauge, normal color")
    func presentationUnknown() {
        let p = MenuBarStyle.presentation(fiveHourPct: nil, sevenDayPct: nil,
                                          showUsage: false, stayAwake: false)
        #expect(p.title == "—")
        #expect(p.gaugeSymbol == "gauge.with.dots.needle.50percent")
        #expect(p.color == nil)
    }

    @Test("First-load → dash title + empty gauge (which the caller pulses)")
    func presentationLoading() {
        let p = MenuBarStyle.presentation(fiveHourPct: nil, sevenDayPct: nil,
                                          showUsage: false, stayAwake: false, isLoading: true)
        #expect(p.title == "—")
        #expect(p.gaugeSymbol == "gauge.with.dots.needle.0percent")
        #expect(p.color == nil)
    }

    // MARK: - Imminent-reset countdown (docs/menubar-states.md ▸ "Imminent reset")

    @Test("Reset within 5 min → minutes shown, rounded up with a floor of 1")
    func countdownWithinWindow() {
        #expect(MenuBarStyle.resetCountdownMinutes(secondsUntilReset: 1) == 1)     // floor
        #expect(MenuBarStyle.resetCountdownMinutes(secondsUntilReset: 60) == 1)
        #expect(MenuBarStyle.resetCountdownMinutes(secondsUntilReset: 61) == 2)    // rounds up
        #expect(MenuBarStyle.resetCountdownMinutes(secondsUntilReset: 300) == 5)   // boundary in
    }

    @Test("Reset outside the 5-min window (or already past) → no countdown")
    func countdownOutsideWindow() {
        #expect(MenuBarStyle.resetCountdownMinutes(secondsUntilReset: 0) == nil)
        #expect(MenuBarStyle.resetCountdownMinutes(secondsUntilReset: -30) == nil)
        #expect(MenuBarStyle.resetCountdownMinutes(secondsUntilReset: 301) == nil)
        #expect(MenuBarStyle.resetCountdownMinutes(secondsUntilReset: 3600) == nil)
    }
}
