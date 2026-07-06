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

    @Test("Claude OAuth source label does not claim primary live data")
    func claudeOAuthSourceLabelDoesNotClaimPrimaryLiveData() {
        let snapshot = QuotaSnapshot(
            source: "Claude Code OAuth",
            primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 1),
            note: nil
        )

        #expect(AppText(language: .english).quotaSnapshotMeta(snapshot).contains("Claude Code OAuth"))
        #expect(!AppText(language: .simplifiedChinese).quotaSnapshotMeta(snapshot).contains("实时"))
        #expect(!AppText(language: .traditionalChinese).quotaSnapshotMeta(snapshot).contains("即時"))
    }

    @Test("cache snapshots do not show freshness badges on account cards")
    func cacheSnapshotsDoNotShowFreshnessBadgesOnAccountCards() {
        let snapshot = QuotaSnapshot(
            source: "Claude Code OAuth Cache",
            primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSinceNow: -60 * 60),
            note: nil
        )

        #expect(AppText(language: .simplifiedChinese).quotaFreshnessBadge(snapshot) == nil)
        #expect(AppText(language: .traditionalChinese).quotaFreshnessBadge(snapshot) == nil)
        #expect(AppText(language: .english).quotaFreshnessBadge(snapshot) == nil)
    }

    @Test("user-facing errors are grouped and hide low-level details")
    func userFacingErrorsAreGroupedAndHideLowLevelDetails() {
        let text = AppText(language: .simplifiedChinese)

        let loginFailure = text.userFacingErrorMessage(
            ProviderError.unsupported("Codex 登录失败：raw browser stack with tokens")
        )
        #expect(loginFailure == "Codex 还没有完成登录。请完成浏览器授权后重试。")
        #expect(!loginFailure.contains("raw browser"))

        let serviceFailure = text.userFacingErrorMessage(
            ProviderError.network("Codex token 刷新失败，HTTP 500")
        )
        #expect(serviceFailure == "这次连接没有完成，QuotaBar 会稍后自动重试。")
        #expect(!serviceFailure.contains("HTTP 500"))

        let updateFailure = text.userFacingErrorMessage(
            UpdateServiceError.digestMismatch(expected: "abc123", actual: "def456")
        )
        #expect(updateFailure == "为确保安全，更新包没有通过校验，QuotaBar 已停止安装。请稍后重试，或从官方发布页下载。")
        #expect(!updateFailure.contains("abc123"))
    }
}
