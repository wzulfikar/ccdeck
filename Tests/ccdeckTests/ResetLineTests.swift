import Testing
import Foundation
@testable import ccdeck

/// Verifies the combined-capacity "Next reset … / Weekly reset …" line.
@Suite("resetLine")
struct ResetLineTests {
    // relativeReset floors against the real clock, so anchor to Date() with a small
    // margin so elapsed test time can't shave a whole-hour bucket down.
    private func at(hours: Double) -> Date { Date().addingTimeInterval(hours * 3600 + 60) }

    @Test("No weekly reset → just the next-reset line")
    func noWeekly() {
        let line = resetLine(next: (at(hours: 2), "Sam"), weekly: nil)
        #expect(line == "Next reset: in 2 hrs (Sam)")
    }

    @Test("Weekly reset == next reset → no weekly tail (soonest is already weekly)")
    func weeklyIsNext() {
        let d = at(hours: 3)
        let line = resetLine(next: (d, "Sam"), weekly: (d, "Sam"))
        #expect(line == "Next reset: in 3 hrs (Sam)")
    }

    @Test("Weekly reset, same account → weekly tail without name")
    func weeklySameAccount() {
        let line = resetLine(next: (at(hours: 2), "Sam"), weekly: (at(hours: 3), "Sam"))
        #expect(line == "Next reset: in 2 hrs (Sam). Weekly reset in 3 hrs.")
    }

    @Test("Weekly reset, different account → weekly tail tags the account")
    func weeklyDifferentAccount() {
        let line = resetLine(next: (at(hours: 2), "Sam"), weekly: (at(hours: 3), "Wildan"))
        #expect(line == "Next reset: in 2 hrs (Sam). Weekly reset in 3 hrs (Wildan).")
    }
}
