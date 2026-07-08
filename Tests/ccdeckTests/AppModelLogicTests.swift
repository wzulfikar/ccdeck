import Testing
import Foundation
@testable import ccdeck

/// Pure static helpers on `AppModel` — exercised without constructing the model (which
/// would spin up SQLite + the Keychain).
@Suite("AppModel helpers")
struct AppModelLogicTests {

    // MARK: - extractLoginURL

    @Test("Pulls the https sign-in URL out of Claude's output")
    func extractsLoginURL() {
        let text = "If the browser didn't open, visit: https://claude.ai/oauth?code=abc then paste"
        #expect(AppModel.extractLoginURL(from: text)
                == URL(string: "https://claude.ai/oauth?code=abc"))
    }

    @Test("Returns nil when there is no URL")
    func noURL() {
        #expect(AppModel.extractLoginURL(from: "Waiting for code…") == nil)
        #expect(AppModel.extractLoginURL(from: "") == nil)
    }

    // MARK: - applyRefresh (splice new tokens into the existing blob JSON)

    @Test("Patches tokens in a flat blob, preserving other keys")
    func refreshFlat() throws {
        let raw = #"{"accessToken":"old","refreshToken":"oldR","expiresAt":1,"subscriptionType":"max"}"#
        let expires = Date(timeIntervalSince1970: 1_700_000_000)
        let out = try #require(AppModel.applyRefresh(to: raw, accessToken: "new",
                                                     refreshToken: "newR", expiresAt: expires))
        let creds = try #require(OAuthCreds.parse(out))
        #expect(creds.accessToken == "new")
        #expect(creds.refreshToken == "newR")
        #expect(creds.expiresAt == expires)
        #expect(creds.subscriptionType == "max")   // untouched key survives
    }

    @Test("Patches tokens nested under claudeAiOauth")
    func refreshNested() throws {
        let raw = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"oldR","expiresAt":1}}"#
        let out = try #require(AppModel.applyRefresh(to: raw, accessToken: "new",
                                                     refreshToken: "newR",
                                                     expiresAt: Date(timeIntervalSince1970: 42)))
        let creds = try #require(OAuthCreds.parse(out))
        #expect(creds.accessToken == "new")
        #expect(creds.refreshToken == "newR")
    }

    @Test("Returns nil for un-parseable JSON")
    func refreshRejectsBad() {
        #expect(AppModel.applyRefresh(to: "not json", accessToken: "a",
                                      refreshToken: "b", expiresAt: Date()) == nil)
    }

    // MARK: - deltaPct (usage window vs. previous period)

    @Test("Positive and negative change relative to the baseline")
    func deltaMagnitude() {
        #expect(AppModel.deltaPct(cur: 130, prev: 100, baselineCovered: true) == 0.30)
        #expect(AppModel.deltaPct(cur: 50, prev: 100, baselineCovered: true) == -0.50)
        #expect(AppModel.deltaPct(cur: 100, prev: 100, baselineCovered: true) == 0.0)
    }

    @Test("Nil when the baseline window isn't fully covered by history")
    func deltaHiddenWhenBaselineTruncated() {
        // Would otherwise read as +∞% off a partial prior period.
        #expect(AppModel.deltaPct(cur: 500, prev: 1, baselineCovered: false) == nil)
    }

    @Test("Nil when the baseline is zero (no prior usage to compare against)")
    func deltaHiddenWhenBaselineZero() {
        #expect(AppModel.deltaPct(cur: 500, prev: 0, baselineCovered: true) == nil)
        #expect(AppModel.deltaPct(cur: 0, prev: 0, baselineCovered: true) == nil)
    }
}
