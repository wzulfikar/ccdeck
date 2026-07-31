import Foundation

enum OAuthError: Error, Sendable {
    case unauthorized          // 401 — token expired/invalid, try refresh
    case rateLimited(retryAfter: TimeInterval?)  // 429 — carries Retry-After when present
    case http(Int)
    case badResponse
    case decode
}

/// Talks to the first-party OAuth endpoints that back Claude Code's `/usage`.
///
/// Verified working with a claude.ai subscription OAuth access token:
///   GET https://api.anthropic.com/api/oauth/usage
///   GET https://api.anthropic.com/api/oauth/profile
/// Headers: Authorization: Bearer <accessToken>,
///          anthropic-beta: oauth-2025-04-20,
///          anthropic-version: 2023-06-01
enum OAuthClient {
    static let apiBase = "https://api.anthropic.com"
    static let betaHeader = "oauth-2025-04-20"
    static let versionHeader = "2023-06-01"

    /// Claude Code's public OAuth client id (used only for token refresh).
    /// NOTE: refresh is **untested** here — see `refresh(_:)`.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoint = "https://console.anthropic.com/v1/oauth/token"

    private static func authed(_ path: String, accessToken: String) -> URLRequest {
        var req = URLRequest(url: URL(string: apiBase + path)!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(versionHeader, forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20
        return req
    }

    private static func run(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw OAuthError.badResponse }
        switch http.statusCode {
        case 200: return data
        case 401: throw OAuthError.unauthorized
        case 429:
            throw OAuthError.rateLimited(retryAfter: retryAfterSeconds(http))
        default: throw OAuthError.http(http.statusCode)
        }
    }

    /// Seconds to wait per the response, from `Retry-After` (delta-seconds or an HTTP-date).
    /// Anthropic 429s set it; nil when absent so the caller falls back to its own backoff.
    private static func retryAfterSeconds(_ resp: HTTPURLResponse) -> TimeInterval? {
        guard let raw = resp.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let secs = TimeInterval(raw) { return max(0, secs) }   // delta-seconds form
        // HTTP-date form (rare here): convert to a delay from now.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = fmt.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    // MARK: - Usage

    static func fetchUsage(accessToken: String) async throws -> Usage {
        let data = try await run(authed("/api/oauth/usage", accessToken: accessToken))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw OAuthError.decode }

        func window(_ key: String) -> (Double, Date?) {
            guard let w = obj[key] as? [String: Any] else { return (0, nil) }
            let pct = (w["utilization"] as? Double) ?? Double(w["utilization"] as? Int ?? 0)
            let reset = (w["resets_at"] as? String).flatMap(parseISO)
            return (pct, reset)
        }

        let (fivePct, fiveReset) = window("five_hour")
        let (sevenPct, sevenReset) = window("seven_day")
        return Usage(
            fiveHourPct: fivePct,
            fiveHourResets: fiveReset,
            sevenDayPct: sevenPct,
            sevenDayResets: sevenReset
        )
    }

    // MARK: - Profile

    static func fetchProfile(accessToken: String) async throws -> Profile {
        let data = try await run(authed("/api/oauth/profile", accessToken: accessToken))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = obj["account"] as? [String: Any],
              let email = acct["email"] as? String
        else { throw OAuthError.decode }

        return Profile(
            email: email,
            displayName: (acct["display_name"] as? String) ?? email,
            hasMax: (acct["has_claude_max"] as? Bool) ?? false,
            hasPro: (acct["has_claude_pro"] as? Bool) ?? false
        )
    }

    // MARK: - Refresh (best-effort, UNTESTED)

    /// Exchanges a refresh token for a fresh access token. The endpoint, client id
    /// and payload shape mirror Claude Code's OAuth flow but have NOT been verified
    /// against a live refresh in this codebase — treat failures as "needs re-login".
    static func refresh(refreshToken: String) async throws
        -> (accessToken: String, refreshToken: String, expiresAt: Date) {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = obj["access_token"] as? String
        else { throw OAuthError.unauthorized }

        let rt = (obj["refresh_token"] as? String) ?? refreshToken
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        return (at, rt, Date().addingTimeInterval(expiresIn))
    }
}

/// ISO8601 parser that tolerates fractional seconds (the API returns e.g.
/// `2026-06-30T18:10:00.224553+00:00`). Formatters are created per-call because
/// `ISO8601DateFormatter` is not `Sendable`; cost is negligible at our poll rate.
func parseISO(_ s: String) -> Date? {
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = frac.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
}
