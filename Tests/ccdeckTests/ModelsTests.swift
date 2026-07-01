import Testing
import Foundation
@testable import ccdeck

@Suite("Usage")
struct UsageTests {
    private func usage(five: Double, seven: Double,
                       fiveReset: Date? = nil, sevenReset: Date? = nil) -> Usage {
        Usage(fiveHourPct: five, fiveHourResets: fiveReset,
              sevenDayPct: seven, sevenDayResets: sevenReset)
    }

    @Test("isExhausted true when either window reaches the threshold")
    func exhaustedEitherWindow() {
        #expect(usage(five: 90, seven: 10).isExhausted(threshold: 90))
        #expect(usage(five: 10, seven: 90).isExhausted(threshold: 90))
        #expect(usage(five: 95, seven: 95).isExhausted(threshold: 90))
    }

    @Test("isExhausted false when both windows are below the threshold")
    func notExhaustedBelow() {
        #expect(!usage(five: 89.9, seven: 89.9).isExhausted(threshold: 90))
        #expect(!usage(five: 0, seven: 0).isExhausted(threshold: 90))
    }

    @Test("soonestReset picks the earliest future reset across both windows")
    func soonestResetPicksEarliestFuture() {
        let now = Date()
        let inOneHour = now.addingTimeInterval(3600)
        let inTwoHours = now.addingTimeInterval(7200)
        let u = usage(five: 0, seven: 0, fiveReset: inTwoHours, sevenReset: inOneHour)
        #expect(u.soonestReset(now: now) == inOneHour)
    }

    @Test("soonestReset ignores past resets")
    func soonestResetIgnoresPast() {
        let now = Date()
        let past = now.addingTimeInterval(-3600)
        let future = now.addingTimeInterval(1800)
        let u = usage(five: 0, seven: 0, fiveReset: past, sevenReset: future)
        #expect(u.soonestReset(now: now) == future)
    }

    @Test("soonestReset is nil when there is no future reset")
    func soonestResetNilWhenNone() {
        let now = Date()
        #expect(usage(five: 0, seven: 0).soonestReset(now: now) == nil)
        let allPast = usage(five: 0, seven: 0,
                            fiveReset: now.addingTimeInterval(-1),
                            sevenReset: now.addingTimeInterval(-2))
        #expect(allPast.soonestReset(now: now) == nil)
    }
}

@Suite("CombinedCapacity")
struct CombinedCapacityTests {
    private func cap(usedFive: Double, count: Int) -> CombinedCapacity {
        CombinedCapacity(usedFiveHour: usedFive, usedSevenDay: 0,
                         total: Double(count) * 100, accountsWithData: count)
    }

    @Test("fractionFiveHour = used / total, 0 when no data")
    func fractionMath() {
        #expect(cap(usedFive: 139, count: 2).fractionFiveHour == 0.695)
        #expect(cap(usedFive: 0, count: 0).fractionFiveHour == 0)
        #expect(!cap(usedFive: 0, count: 0).hasData)
        #expect(cap(usedFive: 10, count: 1).hasData)
    }

    @Test("fiveHourLevel bands: normal < 0.85 ≤ warn < 1.0 ≤ full")
    func levelBands() {
        #expect(cap(usedFive: 0, count: 1).fiveHourLevel == .normal)
        #expect(cap(usedFive: 84, count: 1).fiveHourLevel == .normal)
        #expect(cap(usedFive: 85, count: 1).fiveHourLevel == .warn)   // 0.85 boundary
        #expect(cap(usedFive: 99, count: 1).fiveHourLevel == .warn)
        #expect(cap(usedFive: 100, count: 1).fiveHourLevel == .full)  // 1.0 boundary
        #expect(cap(usedFive: 200, count: 2).fiveHourLevel == .full)
    }
}

@Suite("OAuthCreds.parse")
struct OAuthCredsTests {
    @Test("Parses a flat credential blob")
    func flatBlob() {
        let blob = """
        {"accessToken":"tok","refreshToken":"ref","expiresAt":1700000000000,"subscriptionType":"max"}
        """
        let creds = OAuthCreds.parse(blob)
        #expect(creds?.accessToken == "tok")
        #expect(creds?.refreshToken == "ref")
        #expect(creds?.subscriptionType == "max")
        #expect(creds?.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Parses a blob nested under claudeAiOauth")
    func nestedBlob() {
        let blob = """
        {"claudeAiOauth":{"accessToken":"nested","expiresAt":1700000000000}}
        """
        #expect(OAuthCreds.parse(blob)?.accessToken == "nested")
    }

    @Test("Handles integer expiresAt as well as floating point")
    func integerExpiry() {
        let blob = #"{"accessToken":"t","expiresAt":1700000000000}"#
        #expect(OAuthCreds.parse(blob)?.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Returns nil for a blob with no access token or invalid JSON")
    func rejectsBad() {
        #expect(OAuthCreds.parse(#"{"refreshToken":"r"}"#) == nil)
        #expect(OAuthCreds.parse("not json") == nil)
        #expect(OAuthCreds.parse("") == nil)
    }

    @Test("isExpired reflects expiresAt; nil expiry is never expired")
    func expiry() {
        let past = #"{"accessToken":"t","expiresAt":1000}"#           // 1970-ish
        let future = "{\"accessToken\":\"t\",\"expiresAt\":\(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)}"
        let noExpiry = #"{"accessToken":"t"}"#
        #expect(OAuthCreds.parse(past)?.isExpired == true)
        #expect(OAuthCreds.parse(future)?.isExpired == false)
        #expect(OAuthCreds.parse(noExpiry)?.isExpired == false)
    }
}
