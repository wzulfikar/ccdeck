import Foundation

/// Pure policy for the first-load auto-retry: when the very first usage fetch for an
/// account fails, retry silently on a fixed interval a bounded number of times before
/// giving up and leaving a tappable error. Kept separate from the fetch orchestration so
/// the numbers and the "Retrying…" copy can be unit-tested without a network or timers.
enum RetryPolicy {
    /// Total fetch attempts on first load (the initial try plus retries).
    static let maxAttempts = 10
    /// Base delay between attempts.
    static let interval: TimeInterval = 5

    /// Delay before the next attempt, with random jitter. Multiple accounts that fail on the
    /// same cold-start burst would otherwise retry in lockstep and collide into 429s again;
    /// spreading each retry over `interval ± 40%` breaks that synchronization.
    static func delay(rng: () -> Double = { Double.random(in: 0.6...1.4) }) -> TimeInterval {
        interval * rng()
    }

    /// Whether another attempt should follow the one that just failed.
    static func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maxAttempts
    }

    // MARK: - Poll-time retry (the recurring 30s refresh)

    /// The 30s poll is best-effort, so a transient 429 gets a couple of quick retries
    /// before the error surfaces — otherwise one unlucky burst leaves "Fetch failed"
    /// on screen for the whole interval. Kept short so a slow account never stalls the
    /// sequential poll for long.
    static let pollMaxRetries = 2
    /// Upper bound on any single poll retry wait, so a large server `Retry-After` (or a
    /// far-future HTTP-date) can't block the poll loop for minutes.
    static let pollRetryCap: TimeInterval = 8
    /// Stagger between accounts within one poll pass — mirrors the cold-start stagger so
    /// the recurring refresh doesn't burst the per-IP usage limit the way the first load can.
    static let pollStagger: TimeInterval = 0.4

    /// How long to wait before the next poll retry: honor the server's `Retry-After` when
    /// present (capped), else a gentle linear backoff (2s, 4s, …) also capped.
    static func pollDelay(retryAfter: TimeInterval?, attempt: Int) -> TimeInterval {
        if let ra = retryAfter { return min(ra, pollRetryCap) }
        return min(Double(attempt) * 2, pollRetryCap)
    }

    /// The label shown while waiting to retry: the failure reason plus a "Retrying…" tail —
    /// e.g. `Fetch failed (429). Retrying…`. Once retries are exhausted the caller drops
    /// the tail and leaves the bare error so it reads as a final, tappable state.
    static func retryingMessage(base: String) -> String {
        "\(base). Retrying…"
    }

    /// Hovering a still-retrying row offers to jump the queue: swap the passive "Retrying…"
    /// tail for a "Click to retry now." call to action — e.g.
    /// `Fetch failed (429). Retrying…` → `Fetch failed (429). Click to retry now.`.
    static func hoverMessage(_ message: String) -> String {
        message.replacingOccurrences(of: "Retrying…", with: "Click to retry now.")
    }
}
