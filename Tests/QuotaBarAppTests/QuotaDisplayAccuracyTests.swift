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

}
