import Foundation

/// Total tokens consumed "today" (since local midnight), summed across every Claude
/// Code session on this machine. Not per-account — Claude Code's transcripts aren't
/// tagged with which account was active — but the app only ever shows a combined
/// number anyway.
struct TokenUsageToday: Sendable, Equatable, Codable {
    var input = 0
    var output = 0
    var cacheCreate = 0
    var cacheRead = 0
    var messages = 0
    /// Per-Claude-model token breakdown, keyed by the transcript's `message.model`
    /// (e.g. "claude-opus-4-8"). Kept alongside the aggregate so equivalent API cost
    /// can be priced per model — different models bill at very different rates. Optional
    /// for backward-compat: a value persisted by an older build decodes with this nil.
    var byModel: [String: ModelTokens]? = [:]
    /// Local-midnight this total is for — lets a persisted value be discarded when
    /// reloaded on a later day instead of shown as stale.
    var day: Date = Calendar.current.startOfDay(for: Date())

    /// Everything the model processed: fresh input + output + cache writes + cache
    /// reads. Cache reads usually dominate, so this reads much larger than "new" work.
    var total: Int { input + output + cacheCreate + cacheRead }
}

/// Token counts for a single Claude model, split by billing category.
struct ModelTokens: Sendable, Equatable, Codable {
    var input = 0
    var output = 0
    var cacheCreate = 0
    var cacheRead = 0
    /// Assistant messages priced at this model. Optional for backward-compat: a
    /// `byModel` value persisted by an older build decodes with this nil.
    var messages: Int? = 0

    var total: Int { input + output + cacheCreate + cacheRead }
}

/// One (hour, model) row of the persisted history in `hourly_usage`. `hourEpoch` is a
/// unix timestamp floored to the hour, in UTC — the wall-clock local hour it belongs to
/// is computed at read time so DST/travel can't corrupt stored buckets.
struct HourlyRow: Sendable, Equatable {
    var hourEpoch: Int
    var model: String
    var tokens: ModelTokens
}

/// The span the tokens row + chart show. Clicking the row cycles through these.
enum UsageWindow: String, CaseIterable, Sendable {
    case today, week, month

    var next: UsageWindow {
        switch self { case .today: return .week; case .week: return .month; case .month: return .today }
    }
    /// Row label, e.g. "Tokens today".
    var title: String {
        switch self { case .today: return "Tokens today"; case .week: return "Tokens 7-day"; case .month: return "Tokens 30-day" }
    }
    /// Chart x-axis granularity: hourly bars today, daily bars for the multi-day windows.
    var barUnit: Calendar.Component { self == .today ? .hour : .day }
    /// How far back to shift the window to get the "previous period" baseline for the delta.
    var shiftDays: Int { switch self { case .today: return 1; case .week: return 7; case .month: return 30 } }
    /// Human name of the baseline the delta compares against.
    var baselineLabel: String {
        switch self { case .today: return "yesterday"; case .week: return "previous 7 days"; case .month: return "previous 30 days" }
    }

    /// `[start, end]` for the current period, ending at `now`. `today` runs from local
    /// midnight; the multi-day windows from the start of the day N-1 days ago.
    func range(now: Date, cal: Calendar) -> (start: Date, end: Date) {
        switch self {
        case .today: return (cal.startOfDay(for: now), now)
        case .week:  return (cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: now) ?? now), now)
        case .month: return (cal.startOfDay(for: cal.date(byAdding: .day, value: -29, to: now) ?? now), now)
        }
    }
}

/// One stacked segment of the usage chart: the tokens one model spent in one local
/// hour/day bucket. Bars at the same `date` stack by `model`.
struct UsageBar: Identifiable, Sendable, Equatable {
    let date: Date
    let model: String
    let tokens: Int
    var id: String { "\(date.timeIntervalSince1970)-\(model)" }
}

/// Turns a transcript model id into a compact legend label:
/// "claude-opus-4-8" → "Opus 4.8", "claude-haiku-4-5-20251001" → "Haiku 4.5".
func shortModelName(_ id: String) -> String {
    var s = id
    if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
    let parts = s.split(separator: "-")
    guard let name = parts.first else { return id }
    // Version = the short numeric parts after the name (drop the trailing date stamp).
    let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) && $0.count < 4 }
    let title = name.prefix(1).uppercased() + name.dropFirst()
    return version.isEmpty ? title : "\(title) \(version.joined(separator: "."))"
}

/// The tokens/cost/delta headline for the selected window.
struct UsageSummary: Sendable, Equatable {
    var tokens: Int
    var cost: Double?      // nil until prices load
    var deltaPct: Double?  // vs previous equal-length window; nil when no baseline
}

/// Result of a scan: today's running aggregate (for the existing "Tokens today" row) plus
/// the same data bucketed by hour+model, which the caller upserts into the history store.
struct TokenScan: Sendable {
    var today: TokenUsageToday
    /// hourEpoch → model → tokens, covering only today's hours (the only ones a scan sees).
    var hourly: [Int: [String: ModelTokens]]
}

/// Sums today's token usage from `~/.claude/projects/**/*.jsonl` — Claude Code's
/// per-session transcripts.
///
/// Incremental: it remembers how many bytes of each file it has already consumed and
/// re-reads only what has been appended since (typically a few KB from the one live
/// session). Finished files aren't reopened; the whole tree is walked only to `stat`
/// mtimes and skip anything untouched today. The running total is reset at midnight.
///
/// An `actor` so its cache lives off the main thread and never needs locking.
actor TokenUsageScanner {
    static let shared = TokenUsageScanner()

    private var dayStart: Date?
    private var offsets: [String: UInt64] = [:]   // path → bytes already consumed
    private var seen: Set<String> = []            // requestId/uuid dedup (resumed sessions replay lines)
    private var totals = TokenUsageToday()
    // Today's usage bucketed by hour-epoch → model, rebuilt cumulatively as lines are read
    // this process. Reset at midnight alongside `totals`. The caller mirrors this into the
    // `hourly_usage` history table (replacing today's rows each scan) so it survives restart.
    private var hourly: [Int: [String: ModelTokens]] = [:]

    func scanToday(now: Date = Date()) -> TokenScan {
        let start = Calendar.current.startOfDay(for: now)
        if dayStart != start {                    // new day (or first run) → drop yesterday's cache
            dayStart = start
            offsets = [:]; seen = []; totals = TokenUsageToday(day: start); hourly = [:]
        }

        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return TokenScan(today: totals, hourly: hourly) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            // Untouched since before today → holds nothing we want. stat only, no read.
            if let mod = rv?.contentModificationDate, mod < start { continue }

            let size = UInt64(rv?.fileSize ?? 0)
            let path = url.path
            var offset = offsets[path] ?? 0
            if size < offset { offset = 0 }        // truncated/rotated → re-read from the top
            if size == offset { continue }         // nothing appended since last scan → skip

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

            // A line may be half-written at EOF. Consume only through the last newline
            // and leave the remainder for the next scan, so we never parse a partial line.
            guard let lastNL = data.lastIndex(of: 0x0A) else { continue }
            let complete = data[...lastNL]
            offsets[path] = offset + UInt64(complete.count)

            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let e = parseAssistant(line, iso: iso, isoNoFrac: isoNoFrac),
                      e.ts >= start,
                      seen.insert(e.id).inserted
                else { continue }

                totals.input += e.tok.input
                totals.output += e.tok.output
                totals.cacheCreate += e.tok.cacheCreate
                totals.cacheRead += e.tok.cacheRead
                totals.messages += 1
                accumulate(&totals.byModel, model: e.model, tok: e.tok)
                // Hour bucket (UTC hour floor). Local grouping for daily views happens at read.
                let hour = Int(e.ts.timeIntervalSince1970) / 3600 * 3600
                var bucket = hourly[hour] ?? [:]
                accumulateModel(&bucket, model: e.model, tok: e.tok)
                hourly[hour] = bucket
            }
        }
        return TokenScan(today: totals, hourly: hourly)
    }

    /// One-shot full walk of every transcript, bucketing the last `days` of usage into
    /// (hour, model) rows. Used once to seed the history table from files that predate the
    /// app; unlike `scanToday` it keeps no state and reads every file whole.
    func backfillHistory(days: Int = 60, now: Date = Date()) -> [HourlyRow] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var buckets: [Int: [String: ModelTokens]] = [:]
        var seenAll: Set<String> = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let mod = rv?.contentModificationDate, mod < cutoff { continue }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let e = parseAssistant(line, iso: iso, isoNoFrac: isoNoFrac),
                      e.ts >= cutoff,
                      seenAll.insert(e.id).inserted
                else { continue }
                let hour = Int(e.ts.timeIntervalSince1970) / 3600 * 3600
                var bucket = buckets[hour] ?? [:]
                accumulateModel(&bucket, model: e.model, tok: e.tok)
                buckets[hour] = bucket
            }
        }
        return buckets.flatMap { hour, models in
            models.map { HourlyRow(hourEpoch: hour, model: $0.key, tokens: $0.value) }
        }
    }

    // MARK: - Parsing helpers

    private struct Entry { var ts: Date; var id: String; var model: String; var tok: ModelTokens }

    /// Parses one JSONL line into an assistant-usage entry, or nil if it isn't one.
    private func parseAssistant(
        _ line: Data.SubSequence, iso: ISO8601DateFormatter, isoNoFrac: ISO8601DateFormatter
    ) -> Entry? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let tsString = obj["timestamp"] as? String,
              let ts = iso.date(from: tsString) ?? isoNoFrac.date(from: tsString),
              let msg = obj["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any]
        else { return nil }
        let id = (obj["requestId"] as? String) ?? (obj["uuid"] as? String) ?? tsString
        // Fall back to a stable "unknown" bucket if the line has no model (priced as $0).
        let model = (msg["model"] as? String) ?? "unknown"
        let tok = ModelTokens(
            input: (u["input_tokens"] as? Int) ?? 0,
            output: (u["output_tokens"] as? Int) ?? 0,
            cacheCreate: (u["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheRead: (u["cache_read_input_tokens"] as? Int) ?? 0,
            messages: 1
        )
        return Entry(ts: ts, id: id, model: model, tok: tok)
    }

    private func accumulate(_ byModel: inout [String: ModelTokens]?, model: String, tok: ModelTokens) {
        var m = byModel ?? [:]
        accumulateModel(&m, model: model, tok: tok)
        byModel = m
    }

    private func accumulateModel(_ byModel: inout [String: ModelTokens], model: String, tok: ModelTokens) {
        var mt = byModel[model] ?? ModelTokens()
        mt.input += tok.input; mt.output += tok.output
        mt.cacheCreate += tok.cacheCreate; mt.cacheRead += tok.cacheRead
        mt.messages = (mt.messages ?? 0) + (tok.messages ?? 0)
        byModel[model] = mt
    }
}

/// Compact token count for a tight menu-bar row: "923", "12.3K", "1.2M", "104M", "3.4B".
func formatTokens(_ n: Int) -> String {
    let v = Double(n)
    switch v {
    case 1_000_000_000...:
        return String(format: "%.1fB", v / 1_000_000_000)
    case 1_000_000...:
        return String(format: v >= 10_000_000 ? "%.0fM" : "%.1fM", v / 1_000_000)
    case 1_000...:
        return String(format: v >= 10_000 ? "%.0fK" : "%.1fK", v / 1_000)
    default:
        return "\(n)"
    }
}
