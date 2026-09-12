import Testing
@testable import QuotaBarApp

@Suite("Refresh backoff")
struct RefreshBackoffPolicyTests {
    @Test("backoff grows exponentially and caps")
    func delayGrowth() {
        let policy = RefreshBackoffPolicy(baseDelay: 10, maxDelay: 80)

        #expect(policy.delay(afterFailureCount: 1) == 10)
        #expect(policy.delay(afterFailureCount: 2) == 20)
        #expect(policy.delay(afterFailureCount: 4) == 80)
        #expect(policy.delay(afterFailureCount: 8) == 80)
    }
}
