import Foundation

/// Per-million-token prices for one model, in USD. Mirrors the `cost` object that
/// models.dev publishes: a single `cacheWrite` rate (no 5m/1h split).
struct ModelCost: Sendable, Equatable, Codable {
    var input = 0.0
    var output = 0.0
    var cacheRead = 0.0
    var cacheWrite = 0.0
}

/// Fetches current Anthropic model pricing from models.dev — an open dataset of model
/// metadata. Used to turn today's token totals into an *equivalent* pay-as-you-go API
/// cost (subscription users aren't billed per token; this is "what this would cost on
/// the API"). Cached in the Store and revalidated on launch, stale-while-revalidate.
enum PricingClient {
    static let url = URL(string: "https://models.dev/api.json")!

    /// Returns the Anthropic price table keyed by model id (e.g. "claude-opus-4-8"),
    /// matching the `message.model` string in Claude Code transcripts.
    static func fetch() async throws -> [String: ModelCost] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        // models.dev returns 403 to requests with no User-Agent; send an explicit one.
        req.setValue("ccdeck", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // The full document covers every provider; we only need anthropic.models[*].cost.
        // Parse loosely so an unrelated schema change elsewhere can't break us.
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = (root["anthropic"] as? [String: Any])?["models"] as? [String: Any]
        else { throw URLError(.cannotParseResponse) }

        var table: [String: ModelCost] = [:]
        for (id, value) in models {
            guard let cost = (value as? [String: Any])?["cost"] as? [String: Any] else { continue }
            func num(_ k: String) -> Double { (cost[k] as? NSNumber)?.doubleValue ?? 0 }
            table[id] = ModelCost(
                input: num("input"), output: num("output"),
                cacheRead: num("cache_read"), cacheWrite: num("cache_write")
            )
        }
        return table
    }
}

/// Compact USD amount for the tight menu row: "$0.00", "$3.40", "$104", "$1.2K".
func formatCost(_ usd: Double) -> String {
    switch usd {
    case 1000...:      return String(format: "$%.1fK", usd / 1000)
    case 100...:       return String(format: "$%.0f", usd)
    case 10...:        return String(format: "$%.0f", usd)
    case 1...:         return String(format: "$%.1f", usd)
    case 0.01...:      return String(format: "$%.2f", usd)
    case let v where v > 0: return "<$0.01"
    default:           return "$0.00"
    }
}
