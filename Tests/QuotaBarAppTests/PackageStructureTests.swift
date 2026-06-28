import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Package structure")
struct PackageStructureTests {
    @Test("Quota windows calculate bounded percentages")
    func quotaWindowPercentages() {
        let window = QuotaWindow(label: "5h", used: 25, limit: 100, resetAt: nil)

        #expect(window.remaining == 75)
        #expect(window.usagePercent == 0.25)
        #expect(window.remainingPercent == 75)
    }

    @Test("status bar metric uses the quota bottleneck")
    func statusBarMetricUsesBottleneck() {
        let snapshot = QuotaSnapshot(
            source: "Fixture",
            primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil),
            secondary: QuotaWindow(label: "Weekly", used: 80, limit: 100, resetAt: nil),
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 1),
            note: nil
        )

        #expect(snapshot.statusBarMetric?.title == "Weekly")
        #expect(snapshot.statusBarMetric?.ratio == 0.2)
    }

    @Test("quota freshness treats expired reset windows as stale")
    func quotaFreshnessTreatsExpiredResetWindowsAsStale() {
        let snapshot = QuotaSnapshot(
            source: "Claude Code StatusLine",
            primary: QuotaWindow(
                label: "5h",
                used: 8,
                limit: 100,
                resetAt: Date(timeIntervalSince1970: 1_780_000_000)
            ),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            note: nil
        )

        #expect(
            QuotaFreshness.isStale(
                snapshot,
                now: Date(timeIntervalSince1970: 1_780_000_200)
            )
        )
    }
}
