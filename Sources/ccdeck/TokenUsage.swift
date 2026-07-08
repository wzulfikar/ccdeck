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
    /// Local-midnight this total is for — lets a persisted value be discarded when
    /// reloaded on a later day instead of shown as stale.
    var day: Date = Calendar.current.startOfDay(for: Date())

    /// Everything the model processed: fresh input + output + cache writes + cache
    /// reads. Cache reads usually dominate, so this reads much larger than "new" work.
    var total: Int { input + output + cacheCreate + cacheRead }
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

    func scanToday(now: Date = Date()) -> TokenUsageToday {
        let start = Calendar.current.startOfDay(for: now)
        if dayStart != start {                    // new day (or first run) → drop yesterday's cache
            dayStart = start
            offsets = [:]; seen = []; totals = TokenUsageToday(day: start)
        }

        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return totals }

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
                      obj["type"] as? String == "assistant",
                      let tsString = obj["timestamp"] as? String,
                      let ts = iso.date(from: tsString) ?? isoNoFrac.date(from: tsString),
                      ts >= start
                else { continue }

                let id = (obj["requestId"] as? String) ?? (obj["uuid"] as? String) ?? tsString
                guard seen.insert(id).inserted else { continue }

                guard let msg = obj["message"] as? [String: Any],
                      let u = msg["usage"] as? [String: Any] else { continue }
                totals.input += (u["input_tokens"] as? Int) ?? 0
                totals.output += (u["output_tokens"] as? Int) ?? 0
                totals.cacheCreate += (u["cache_creation_input_tokens"] as? Int) ?? 0
                totals.cacheRead += (u["cache_read_input_tokens"] as? Int) ?? 0
                totals.messages += 1
            }
        }
        return totals
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
