import Testing
@testable import ccdeck

@Suite("RetryPolicy")
struct RetryPolicyTests {
    @Test("First-load fetches up to 5 times, 5s apart")
    func limits() {
        #expect(RetryPolicy.maxAttempts == 5)
        #expect(RetryPolicy.interval == 5)
    }

    @Test("Keeps retrying until the last attempt, then stops")
    func shouldRetry() {
        #expect(RetryPolicy.shouldRetry(afterAttempt: 1))
        #expect(RetryPolicy.shouldRetry(afterAttempt: 4))
        #expect(!RetryPolicy.shouldRetry(afterAttempt: 5))   // 5th is the last try
        #expect(!RetryPolicy.shouldRetry(afterAttempt: 6))
    }

    @Test("Retrying label appends the tail to the failure reason")
    func retryingMessage() {
        #expect(RetryPolicy.retryingMessage(base: "Fetch failed (429)")
                == "Fetch failed (429) — Retrying…")
        #expect(RetryPolicy.retryingMessage(base: "Offline") == "Offline — Retrying…")
    }

    @Test("Hover swaps the Retrying… tail for a Click to retry now. call to action")
    func hoverMessage() {
        #expect(RetryPolicy.hoverMessage("Fetch failed (429) — Retrying…")
                == "Fetch failed (429) — Click to retry now.")
        // No "Retrying…" tail (e.g. after giving up) → left unchanged.
        #expect(RetryPolicy.hoverMessage("Fetch failed (429)") == "Fetch failed (429)")
    }
}
