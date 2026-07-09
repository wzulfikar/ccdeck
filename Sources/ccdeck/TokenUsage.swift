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

/// Activity counts for a period, aggregated from the persisted hourly insight history (see
/// `InsightRow`). Built by `Store.insights(fromEpoch:toEpoch:)` for whatever span the panel
/// is showing, so it survives the transcripts being cleared.
struct TodayInsights: Sendable, Equatable, Codable {
    /// User-typed prompts (excludes tool-result turns, meta lines, and subagent sidechains).
    var prompts = 0
    /// Total tool invocations across all sessions.
    var toolCalls = 0
    /// Assistant lines flagged `isApiErrorMessage` whose text is a usage/rate-limit notice.
    var rateLimited = 0
    /// Distinct sessions active in the period.
    var sessions = 0
    /// Raw `tool_use` name → count. Built-in tools, `Skill`, and `mcp__server__tool` names
    /// all land here; the UI splits them into built-in / skill / MCP leaderboards.
    var toolCounts: [String: Int] = [:]
    /// Skill slug (from a `Skill` tool_use's `input.skill`) → count.
    var skillCounts: [String: Int] = [:]

    /// Built-in tools only (excludes `mcp__…` tools and the `Skill` dispatcher, which get
    /// their own leaderboards).
    var builtInToolCounts: [String: Int] {
        toolCounts.filter { !$0.key.hasPrefix("mcp__") && $0.key != "Skill" }
    }
    /// `mcp__server__tool` calls only.
    var mcpCounts: [String: Int] { toolCounts.filter { $0.key.hasPrefix("mcp__") } }

    /// Top `n` entries of a count map, highest first, ties broken by name for stability.
    static func top(_ counts: [String: Int], _ n: Int = 3) -> [(name: String, count: Int)] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(n).map { (name: $0.key, count: $0.value) }
    }
}

/// One persisted activity count for a single hour, in a uniform shape so one table holds
/// everything: `kind` names the metric, `name` labels the tool/skill/session ("" for the
/// scalar kinds), and `count` is that hour's tally. Aggregating a period sums the scalar
/// kinds, groups the `tool`/`skill` kinds by name, and counts distinct `session` names.
struct InsightRow: Sendable, Equatable {
    var hourEpoch: Int
    var kind: String   // "prompt" | "toolCall" | "rateLimited" | "tool" | "skill" | "session"
    var name: String
    var count: Int
}

/// Result of a scan: today's running aggregate (for the existing "Tokens today" row), the
/// same data bucketed by hour+model (upserted into the history store), and today's hourly
/// insight rows (which replace today's rows in the insight history).
struct TokenScan: Sendable {
    var today: TokenUsageToday
    /// hourEpoch → model → tokens, covering only today's hours (the only ones a scan sees).
    var hourly: [Int: [String: ModelTokens]]
    var insights: [InsightRow]
}

/// One-shot history seed from the whole transcript tree: token rows + insight rows.
struct HistoryBackfill: Sendable {
    var hourly: [HourlyRow]
    var insights: [InsightRow]
}

/// One hour's activity, accumulated during a scan before being flattened into `InsightRow`s.
private struct InsightBucket {
    var prompts = 0
    var toolCalls = 0
    var rateLimited = 0
    var toolCounts: [String: Int] = [:]
    var skillCounts: [String: Int] = [:]
    var sessions: Set<String> = []
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
    // Today's activity bucketed by hour-epoch, rebuilt cumulatively this process alongside
    // `hourly` and reset at midnight. The caller flattens it to `InsightRow`s and replaces
    // today's rows in the `hourly_insight` history so the panel can query any period.
    private var hourlyInsights: [Int: InsightBucket] = [:]

    func scanToday(now: Date = Date()) -> TokenScan {
        let start = Calendar.current.startOfDay(for: now)
        if dayStart != start {                    // new day (or first run) → drop yesterday's cache
            dayStart = start
            offsets = [:]; seen = []; totals = TokenUsageToday(day: start); hourly = [:]
            hourlyInsights = [:]
        }

        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return TokenScan(today: totals, hourly: hourly, insights: Self.rows(from: hourlyInsights)) }

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
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let tsString = obj["timestamp"] as? String,
                      let ts = iso.date(from: tsString) ?? isoNoFrac.date(from: tsString),
                      ts >= start
                else { continue }
                // Dedup the whole line by uuid (resumed sessions replay old lines verbatim).
                let uid = (obj["uuid"] as? String) ?? (obj["requestId"] as? String) ?? tsString
                guard seen.insert(uid).inserted else { continue }
                let hour = Int(ts.timeIntervalSince1970) / 3600 * 3600
                if obj["type"] as? String == "assistant" { ingestTokens(obj, ts: ts) }
                Self.tally(obj, into: &hourlyInsights[hour, default: InsightBucket()])
            }
        }
        return TokenScan(today: totals, hourly: hourly, insights: Self.rows(from: hourlyInsights))
    }

    /// Flatten hourly activity buckets into the uniform `InsightRow` shape for storage.
    private static func rows(from buckets: [Int: InsightBucket]) -> [InsightRow] {
        var out: [InsightRow] = []
        for (hour, b) in buckets {
            if b.prompts > 0 { out.append(InsightRow(hourEpoch: hour, kind: "prompt", name: "", count: b.prompts)) }
            if b.toolCalls > 0 { out.append(InsightRow(hourEpoch: hour, kind: "toolCall", name: "", count: b.toolCalls)) }
            if b.rateLimited > 0 { out.append(InsightRow(hourEpoch: hour, kind: "rateLimited", name: "", count: b.rateLimited)) }
            for (n, c) in b.toolCounts { out.append(InsightRow(hourEpoch: hour, kind: "tool", name: n, count: c)) }
            for (n, c) in b.skillCounts { out.append(InsightRow(hourEpoch: hour, kind: "skill", name: n, count: c)) }
            for s in b.sessions { out.append(InsightRow(hourEpoch: hour, kind: "session", name: s, count: 1)) }
        }
        return out
    }

    /// Fold one line's activity into an hour bucket (prompts / tool calls / rate-limits /
    /// leaderboards / the session that produced it).
    private static func tally(_ obj: [String: Any], into b: inout InsightBucket) {
        if let sid = obj["sessionId"] as? String { b.sessions.insert(sid) }
        switch obj["type"] as? String {
        case "assistant":
            let msg = obj["message"] as? [String: Any]
            // Usage/rate-limit notices are assistant lines flagged as API errors.
            if obj["isApiErrorMessage"] as? Bool == true {
                if let text = msg?["content"] as? String, isLimitNotice(text) { b.rateLimited += 1 }
                return
            }
            // Tool calls: count every tool_use block; record Skill invocations by slug.
            if let content = msg?["content"] as? [[String: Any]] {
                for blk in content where blk["type"] as? String == "tool_use" {
                    guard let name = blk["name"] as? String else { continue }
                    b.toolCalls += 1
                    b.toolCounts[name, default: 0] += 1
                    if name == "Skill", let slug = (blk["input"] as? [String: Any])?["skill"] as? String {
                        b.skillCounts[slug, default: 0] += 1
                    }
                }
            }
        case "user":
            // Count only user-typed prompts: skip system-injected meta lines, subagent
            // sidechains, and tool-result carrier turns (no text block).
            if obj["isMeta"] as? Bool == true || obj["isSidechain"] as? Bool == true { return }
            let content = (obj["message"] as? [String: Any])?["content"]
            let isPrompt = content is String
                || (content as? [[String: Any]])?.contains { $0["type"] as? String == "text" } == true
            if isPrompt { b.prompts += 1 }
        default:
            break
        }
    }

    /// Fold one assistant line into the token totals and hour buckets.
    private func ingestTokens(_ obj: [String: Any], ts: Date) {
        let msg = obj["message"] as? [String: Any]
        // Token usage (only present on model-response lines).
        guard let u = msg?["usage"] as? [String: Any] else { return }
        let model = (msg?["model"] as? String) ?? "unknown"
        let tok = ModelTokens(
            input: (u["input_tokens"] as? Int) ?? 0,
            output: (u["output_tokens"] as? Int) ?? 0,
            cacheCreate: (u["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheRead: (u["cache_read_input_tokens"] as? Int) ?? 0,
            messages: 1
        )
        totals.input += tok.input
        totals.output += tok.output
        totals.cacheCreate += tok.cacheCreate
        totals.cacheRead += tok.cacheRead
        totals.messages += 1
        accumulate(&totals.byModel, model: model, tok: tok)
        // Hour bucket (UTC hour floor). Local grouping for daily views happens at read.
        let hour = Int(ts.timeIntervalSince1970) / 3600 * 3600
        var bucket = hourly[hour] ?? [:]
        accumulateModel(&bucket, model: model, tok: tok)
        hourly[hour] = bucket
    }

    /// True for the assistant-side usage/rate-limit notices Claude Code writes on 429s,
    /// e.g. "You've hit your session limit · resets 3:30pm". Excludes unrelated API errors
    /// (e.g. "Not logged in") so the count reflects rate limiting specifically.
    static func isLimitNotice(_ text: String) -> Bool {
        let s = text.lowercased()
        return s.contains("limit") || s.contains("429") || s.contains("overloaded")
    }

    /// One-shot full walk of every transcript, bucketing the last `days` of usage into
    /// (hour, model) token rows and (hour, kind, name) insight rows. Used once to seed the
    /// history tables from files that predate the app; unlike `scanToday` it keeps no state
    /// and reads every file whole.
    func backfillHistory(days: Int = 60, now: Date = Date()) -> HistoryBackfill {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return HistoryBackfill(hourly: [], insights: []) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var buckets: [Int: [String: ModelTokens]] = [:]
        var insightBuckets: [Int: InsightBucket] = [:]
        var seenAll: Set<String> = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let mod = rv?.contentModificationDate, mod < cutoff { continue }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                // Parse once for both token and activity accumulation (all line types).
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let tsString = obj["timestamp"] as? String,
                      let ts = iso.date(from: tsString) ?? isoNoFrac.date(from: tsString),
                      ts >= cutoff
                else { continue }
                let uid = (obj["uuid"] as? String) ?? (obj["requestId"] as? String) ?? tsString
                guard seenAll.insert(uid).inserted else { continue }
                let hour = Int(ts.timeIntervalSince1970) / 3600 * 3600
                if obj["type"] as? String == "assistant",
                   let msg = obj["message"] as? [String: Any],
                   let u = msg["usage"] as? [String: Any] {
                    let model = (msg["model"] as? String) ?? "unknown"
                    let tok = ModelTokens(
                        input: (u["input_tokens"] as? Int) ?? 0,
                        output: (u["output_tokens"] as? Int) ?? 0,
                        cacheCreate: (u["cache_creation_input_tokens"] as? Int) ?? 0,
                        cacheRead: (u["cache_read_input_tokens"] as? Int) ?? 0,
                        messages: 1
                    )
                    var bucket = buckets[hour] ?? [:]
                    accumulateModel(&bucket, model: model, tok: tok)
                    buckets[hour] = bucket
                }
                Self.tally(obj, into: &insightBuckets[hour, default: InsightBucket()])
            }
        }
        let hourly = buckets.flatMap { hour, models in
            models.map { HourlyRow(hourEpoch: hour, model: $0.key, tokens: $0.value) }
        }
        return HistoryBackfill(hourly: hourly, insights: Self.rows(from: insightBuckets))
    }

    // MARK: - Parsing helpers

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
