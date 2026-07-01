import Foundation

/// Pure policy for the first-load auto-retry: when the very first usage fetch for an
/// account fails, retry silently on a fixed interval a bounded number of times before
/// giving up and leaving a tappable error. Kept separate from the fetch orchestration so
/// the numbers and the "Retrying…" copy can be unit-tested without a network or timers.
enum RetryPolicy {
    /// Total fetch attempts on first load (the initial try plus retries).
    static let maxAttempts = 5
    /// Delay between attempts.
    static let interval: TimeInterval = 5

    /// Whether another attempt should follow the one that just failed.
    static func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maxAttempts
    }

    /// The label shown while waiting to retry: the failure reason plus a "Retrying…" tail —
    /// e.g. `Fetch failed (429) — Retrying…`. Once retries are exhausted the caller drops
    /// the tail and leaves the bare error so it reads as a final, tappable state.
    static func retryingMessage(base: String) -> String {
        "\(base) — Retrying…"
    }

    /// Hovering a still-retrying row offers to jump the queue: swap the passive "Retrying…"
    /// tail for a "Click to retry now." call to action — e.g.
    /// `Fetch failed (429) — Retrying…` → `Fetch failed (429) — Click to retry now.`.
    static func hoverMessage(_ message: String) -> String {
        message.replacingOccurrences(of: "Retrying…", with: "Click to retry now.")
    }
}
