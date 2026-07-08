import Testing
import Foundation
@testable import ccdeck

@Suite("formatTokens")
struct TokenUsageTests {
    @Test("Sub-thousand shows raw count")
    func raw() {
        #expect(formatTokens(0) == "0")
        #expect(formatTokens(923) == "923")
    }

    @Test("Thousands: one decimal under 10K, none from 10K up")
    func thousands() {
        #expect(formatTokens(1_200) == "1.2K")
        #expect(formatTokens(12_300) == "12K")
        #expect(formatTokens(999_000) == "999K")
    }

    @Test("Millions: one decimal under 10M, none from 10M up")
    func millions() {
        #expect(formatTokens(1_200_000) == "1.2M")
        #expect(formatTokens(103_930_001) == "104M")
    }

    @Test("Billions")
    func billions() {
        #expect(formatTokens(3_400_000_000) == "3.4B")
    }

    @Test("total sums all four token kinds")
    func total() {
        let t = TokenUsageToday(input: 1, output: 2, cacheCreate: 4, cacheRead: 8, messages: 1)
        #expect(t.total == 15)
    }
}

@Suite("ModelTokens")
struct ModelTokensTests {
    @Test("total sums the four token kinds, ignoring messages")
    func total() {
        let t = ModelTokens(input: 1, output: 2, cacheCreate: 4, cacheRead: 8, messages: 3)
        #expect(t.total == 15)
    }

    @Test("A blob without messages decodes with nil (backward-compat)")
    func decodesLegacyWithoutMessages() throws {
        let json = #"{"input":1,"output":2,"cacheCreate":4,"cacheRead":8}"#.data(using: .utf8)!
        let t = try JSONDecoder().decode(ModelTokens.self, from: json)
        #expect(t.total == 15)
        #expect(t.messages == nil)
    }
}

@Suite("shortModelName")
struct ShortModelNameTests {
    @Test("Strips the claude- prefix and capitalises the family name")
    func basic() {
        #expect(shortModelName("claude-opus-4-8") == "Opus 4.8")
        #expect(shortModelName("claude-sonnet-5") == "Sonnet 5")
    }

    @Test("Drops the trailing date stamp from the version")
    func dropsDateStamp() {
        #expect(shortModelName("claude-haiku-4-5-20251001") == "Haiku 4.5")
    }

    @Test("Passes through ids with no version and unknown buckets")
    func noVersion() {
        #expect(shortModelName("unknown") == "Unknown")
        #expect(shortModelName("claude-opus") == "Opus")
    }
}

@Suite("UsageWindow")
struct UsageWindowTests {
    @Test("next cycles today → week → month → today")
    func cycle() {
        #expect(UsageWindow.today.next == .week)
        #expect(UsageWindow.week.next == .month)
        #expect(UsageWindow.month.next == .today)
    }

    @Test("barUnit is hourly for today, daily otherwise")
    func barUnit() {
        #expect(UsageWindow.today.barUnit == .hour)
        #expect(UsageWindow.week.barUnit == .day)
        #expect(UsageWindow.month.barUnit == .day)
    }

    @Test("shiftDays matches the window span for the previous-period baseline")
    func shiftDays() {
        #expect(UsageWindow.today.shiftDays == 1)
        #expect(UsageWindow.week.shiftDays == 7)
        #expect(UsageWindow.month.shiftDays == 30)
    }

    @Test("range: today starts at local midnight, ending now")
    func rangeToday() {
        let cal = Calendar.current
        let now = Date()
        let (start, end) = UsageWindow.today.range(now: now, cal: cal)
        #expect(start == cal.startOfDay(for: now))
        #expect(end == now)
    }

    @Test("range: multi-day windows span N-1 days back to the start of that day")
    func rangeMultiDay() {
        let cal = Calendar.current
        let now = Date()
        let week = UsageWindow.week.range(now: now, cal: cal)
        #expect(week.start == cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: now)!))
        #expect(week.end == now)

        let month = UsageWindow.month.range(now: now, cal: cal)
        #expect(month.start == cal.startOfDay(for: cal.date(byAdding: .day, value: -29, to: now)!))
    }
}
