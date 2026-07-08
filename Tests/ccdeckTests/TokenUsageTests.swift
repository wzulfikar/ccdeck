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
