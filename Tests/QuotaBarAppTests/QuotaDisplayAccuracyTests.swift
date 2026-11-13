import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Quota display accuracy")
struct QuotaDisplayAccuracyTests {
    private func snapshot(at: Date = Date(), primary: QuotaWindow? = nil, secondary: QuotaWindow? = nil, extras: [QuotaWindow] = []) -> QuotaSnapshot {
        QuotaSnapshot(source: "Codex OAuth", primary: primary, secondary: secondary, extraWindows: extras,
                      creditsRemaining: nil, creditsTotal: nil, updatedAt: at, note: nil)
    }

    @Test("exhausted model or review bucket cannot exhaust account-wide quotas")
    func independentBuckets() {
        let core = QuotaWindow(label: "5h", used: 20, limit: 100, resetAt: nil)
        let extra = QuotaWindow(label: "Code Review Weekly", used: 100, limit: 100, resetAt: nil)
        let quota = snapshot(primary: core, extras: [extra])
        #expect(!quota.hasExhaustedQuota)
        #expect(AccountCardStatusPresenter.status(tool: .codex, quota: quota, loadState: .loaded, isRefreshing: false, errorMessage: nil, errorRequiresUserAction: false) == .healthy)
        #expect(quota.statusBarMetric?.ratio == 0.8)
        #expect(quota.mainMetrics(for: .codex) == [.window(core)])
        #expect(quota.supplementaryMetrics(for: .codex) == [.window(extra)])
        let account = Account(tool: .codex, name: "Fixture")
        #expect(AccountListPresenter.isAccountAvailable(account, quotaByAccount: [account.id: quota]))
    }

    @Test("all Claude model windows survive without occupying the global weekly slot")
    func allModelWindows() {
        let limits: [[String: Any]] = [
            ["group": "session", "percent": 10],
            ["group": "weekly", "percent": 20],
            ["group": "weekly", "percent": 30, "scope": ["model": ["display_name": "A"]]],
            ["group": "weekly", "percent": 100, "scope": ["model": ["display_name": "B"]]]
        ]
        let quota = ClaudeCodeProvider().parseOAuthUsagePayloadForTesting(["limits": limits])
        #expect(quota.orderedMetrics.count == 4)
        #expect(quota.mainMetrics(for: .claudeCode).map(\.title) == ["5h", "7d"])
        #expect(quota.supplementaryMetrics(for: .claudeCode).count == 2)
        #expect(!quota.hasExhaustedQuota)
    }

    @Test("mixed historical values retain the oldest timestamp")
    func historicalMerge() {
        let now = Date()
        let old = snapshot(at: now.addingTimeInterval(-1200), secondary: QuotaWindow(label: "7d", used: 80, limit: 100, resetAt: now.addingTimeInterval(86400)))
        let fresh = snapshot(at: now, primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: now.addingTimeInterval(3600)))
        let merged = ClaudeCodeProvider().mergeClaudeSnapshot(fresh, fillingMissingMetricsFrom: old)
        #expect(merged.secondary == old.secondary)
        #expect(merged.updatedAt == old.updatedAt)
        #expect(QuotaFreshness.isStale(merged, now: now))
    }

    @Test("menu exposes stale data and each window's own reset")
    func menuFreshnessAndReset() throws {
        let reset = Date().addingTimeInterval(3600)
        let quota = snapshot(at: Date().addingTimeInterval(-7200), primary: QuotaWindow(label: "5h", used: 20, limit: 100, resetAt: nil), secondary: QuotaWindow(label: "Weekly", used: 30, limit: 100, resetAt: reset))
        let entries = StatusBarQuotaPresenter.entries(for: [.init(tool: .codex, accountName: "Fixture", quota: quota)])
        let entry = try #require(entries.first)
        #expect(entry.isStale)
        #expect(entry.resetWindows.first?.resetAt == nil)
        let tooltip = StatusBarQuotaPresenter.tooltip(for: entries, text: AppText(language: .english))
        #expect(tooltip.contains("Reset time unavailable"))
        #expect(tooltip.contains("Resets in"))
    }

    @Test("reset countdown reaches pending confirmation without inventing quota")
    func resetBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for language in AppLanguage.allCases {
            let text = AppText(language: language)
            #expect(!text.resetCountdown(now.addingTimeInterval(3600), now: now).isEmpty)
            #expect(text.resetCountdown(now, now: now) == text.resetCountdown(now.addingTimeInterval(-60), now: now))
            #expect(!text.exactReset(now).isEmpty)
        }
    }

    @Test("identity alone is not quota evidence")
    func unknownAccount() {
        let account = Account(tool: .claudeCode, name: "Fixture")
        let quota = QuotaSnapshot(source: "Claude Code", accountIdentifier: "fixture@example.com", primary: nil, secondary: nil, creditsRemaining: nil, creditsTotal: nil, updatedAt: Date(), note: "Waiting")
        #expect(!AccountListPresenter.isAccountAvailable(account, quotaByAccount: [account.id: quota]))
    }
    @Test("reset-boundary fetch bypasses ordinary cache but respects server cooldown")
    func resetBypassesCache() {
        let now = Date()
        let quota = snapshot(primary: QuotaWindow(label: "5h", used: 100, limit: 100, resetAt: now.addingTimeInterval(-10)))
        let cached = ClaudeCodeProvider.CachedClaudeUsage(schemaVersion: 1, cachedAt: now.addingTimeInterval(-20), snapshot: quota)
        let provider = ClaudeCodeProvider()
        #expect(provider.oauthUsagePreflight(cached: cached, rateLimitMarkerIsFresh: false, intent: .visible, now: now).shouldRequestNetwork)
        #expect(!provider.oauthUsagePreflight(cached: cached, rateLimitMarkerIsFresh: true, intent: .visible, now: now).shouldRequestNetwork)
        #expect(!provider.oauthUsagePreflight(cached: cached, rateLimitMarkerIsFresh: false, intent: .local, now: now).shouldRequestNetwork)
    }

    @Test("legacy Claude model quotas are preserved separately")
    func legacyModelQuotas() {
        let quota = ClaudeCodeProvider().parseOAuthUsagePayloadForTesting([
            "five_hour": ["utilization": 20],
            "seven_day": ["utilization": 30],
            "seven_day_opus": ["utilization": 100],
            "seven_day_sonnet": ["utilization": 40]
        ])
        #expect(quota.mainMetrics(for: .claudeCode).count == 2)
        #expect(Set(quota.supplementaryMetrics(for: .claudeCode).map(\.title)) == Set(["7d·Opus", "7d·Sonnet"]))
        #expect(!quota.hasExhaustedQuota)
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

    @Test("stale-data age humanizes to minutes, hours, and days")
    func humanizedAgeFormatting() {
        #expect(AppText.humanizedAge(minutes: 12, language: .simplifiedChinese) == "12 分钟")
        #expect(AppText.humanizedAge(minutes: 480, language: .simplifiedChinese) == "8 小时")
        #expect(AppText.humanizedAge(minutes: 480, language: .traditionalChinese) == "8 小時")
        #expect(AppText.humanizedAge(minutes: 3000, language: .simplifiedChinese) == "2 天")
        #expect(AppText.humanizedAge(minutes: 90, language: .english) == "1 hour")
        #expect(AppText.humanizedAge(minutes: 2880, language: .english) == "2 days")
    }

    @Test("credential guidance note localizes and shows on the card")
    func credentialGuidanceNoteLocalization() {
        let note = QuotaNoteCatalog.claudeCredentialsAwaitingClaudeCode
        let en = AppText(language: .english)
        #expect(en.localizedNote(note)?.contains("live data resumes") == true)
        #expect(en.shouldDisplayNoteOnCard(note))
        let zh = AppText(language: .simplifiedChinese)
        #expect(zh.localizedNote(note) == note)
    }
}
