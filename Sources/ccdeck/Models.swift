import Foundation

/// A managed Claude account. The credential blob itself lives in the Keychain
/// (service `Keychain.appService`, account == `email`); this struct only carries
/// identity + display metadata, which is persisted in SQLite.
struct Account: Identifiable, Hashable, Codable, Sendable {
    var email: String
    var label: String
    var plan: String          // "pro" | "max" | ...
    var order: Int            // insertion order; drives "circle back to first"

    var id: String { email }
}

/// Parsed view of a Claude Code OAuth credential blob.
///
/// `raw` is the *exact* JSON string as stored in the Keychain. We always write
/// this back verbatim when activating an account — never reconstruct it — so a
/// token can't be corrupted by a round-trip through our own encoder. Parsing is
/// only ever done on a copy to pull out the access token / expiry.
struct OAuthCreds: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var subscriptionType: String?
    var raw: String

    static func parse(_ raw: String) -> OAuthCreds? {
        guard let data = raw.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Blob may be flat or nested under "claudeAiOauth".
        let o = (top["claudeAiOauth"] as? [String: Any]) ?? top
        guard let at = o["accessToken"] as? String else { return nil }

        var expires: Date?
        if let ms = o["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = o["expiresAt"] as? Int {
            expires = Date(timeIntervalSince1970: Double(ms) / 1000)
        }

        return OAuthCreds(
            accessToken: at,
            refreshToken: o["refreshToken"] as? String,
            expiresAt: expires,
            subscriptionType: o["subscriptionType"] as? String,
            raw: raw
        )
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

/// One quota reading for an account (the two windows we care about).
struct Usage: Sendable, Equatable {
    var fiveHourPct: Double
    var fiveHourResets: Date?
    var sevenDayPct: Double
    var sevenDayResets: Date?
    var fetchedAt: Date = Date()

    /// True if either window is at/above the rotation threshold.
    func isExhausted(threshold: Double) -> Bool {
        fiveHourPct >= threshold || sevenDayPct >= threshold
    }

    /// Soonest upcoming reset across both windows (5-hour or 7-day), or nil if none
    /// is in the future.
    func soonestReset(now: Date = Date()) -> Date? {
        [fiveHourResets, sevenDayResets].compactMap { $0 }.filter { $0 > now }.min()
    }
}

/// Account identity from `/api/oauth/profile`.
struct Profile: Sendable {
    var email: String
    var displayName: String
    var hasMax: Bool
    var hasPro: Bool

    var plan: String { hasMax ? "max" : (hasPro ? "pro" : "free") }
}

/// Aggregated history for the summary section.
struct UsageSummary: Sendable {
    var peakFiveHour: Double
    var peakSevenDay: Double
    var samples: Int
}

/// Total quota across every account with live data. With N accounts you have N×
/// the quota, so `total` is `100 * N` and `used` is the sum of utilizations — e.g.
/// two accounts at 100% and 39% read as 139% of 200%.
struct CombinedCapacity: Sendable {
    var usedFiveHour: Double
    var usedSevenDay: Double
    var total: Double
    var accountsWithData: Int

    var hasData: Bool { total > 0 }

    /// Utilization of the current (5-hour) window, 0–1.
    var fractionFiveHour: Double { total > 0 ? usedFiveHour / total : 0 }

    /// Drives the menu-bar icon color. Based on how much combined capacity is *used*:
    /// safe → white, almost depleted → orange, all used → red.
    var fiveHourLevel: CapacityLevel {
        let f = fractionFiveHour
        if f >= 1.0 { return .full }   // all capacity used → red
        if f >= 0.85 { return .warn }  // almost depleted → orange
        return .normal                 // safe → white
    }
}

/// Color band for the menu-bar icon. `warn` = orange (almost out), `full` = red (out).
enum CapacityLevel: Sendable { case normal, warn, full }
