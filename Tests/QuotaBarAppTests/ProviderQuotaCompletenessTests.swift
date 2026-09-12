import Foundation
import Testing
@testable import QuotaBarApp

struct ProviderQuotaCompletenessTests {
    @Test func fractionalPercentagesRemainPercentagePoints() throws {
        for used in [0.0, 0.5, 1.0, 35.0, 100.0] {
            let codex = try #require(CodexProvider().parseRateLimitPayloadForTesting([
                "rate_limit": ["primary_window": ["used_percent": used], "secondary_window": ["used_percent": used]]
            ]))
            #expect(codex.primary?.used == used)
            #expect(codex.mainMetrics(for: .codex).count == 2)
            #expect(CursorProvider().parsePercentWindow(label: "Total", usedPercent: used, resetAt: nil)?.used == used)
        }
    }

    @Test func claudeScopedAndRoutinesStaySeparateFromAccountQuota() {
        let snapshot = ClaudeCodeProvider().parseOAuthUsagePayloadForTesting([
            "limits": [
                ["kind": "session", "percent": 0.5],
                ["kind": "weekly_scoped", "percent": 20, "scope": ["model": ["display_name": "All models"]]],
                ["kind": "weekly_scoped", "percent": 100, "scope": ["model": ["display_name": "Fable"]]]
            ],
            "seven_day_routines": ["utilization": 100],
            "extra_usage": ["is_enabled": true, "used_credits": 1250, "monthly_limit": 5000, "currency": "USD"]
        ])
        #expect(snapshot.primary?.used == 0.5)
        #expect(snapshot.secondary?.label == "7d")
        #expect(Set(snapshot.supplementaryMetrics(for: .claudeCode).map(\.title)) == ["7d·Fable", "Routines 7d"])
        #expect(!snapshot.hasExhaustedQuota)
        #expect(snapshot.spending.first?.used == 12.5)
        #expect(snapshot.spending.first?.limit == 50)
        #expect(snapshot.spending.first?.resetAt == nil)
    }

    @Test func disabledOrMissingClaudeSpendIsNotZero() {
        let provider = ClaudeCodeProvider()
        #expect(provider.parseExtraUsageSpend(["is_enabled": false, "used_credits": 0]) == nil)
        #expect(provider.parseExtraUsageSpend(["is_enabled": true]) == nil)
        #expect(provider.parseExtraUsageSpend(["is_enabled": true, "used_credits": 0])?.used == 0)
    }

    @Test func cursorSpendDoesNotFabricateAQuotaLimit() throws {
        let provider = CursorProvider()
        let credentials = CursorProvider.CursorCredentials(accessToken: "fixture", refreshToken: nil, email: "test@example.com", membershipType: "pro", subscriptionStatus: nil, subscriptionPeriodEnd: nil, stateDatabasePath: nil, source: "fixture")
        let snapshot = try provider.parseUsageSummaryFallback(summary: [
            "individualUsage": [
                "plan": ["totalPercentUsed": 25, "autoPercentUsed": 10, "apiPercentUsed": 30],
                "onDemand": ["enabled": true, "used": 1250]
            ]
        ], requestUsage: nil, credentials: credentials, planName: "pro")
        #expect(snapshot.mainMetrics(for: .cursor).count == 3)
        #expect(!snapshot.hasExhaustedQuota)
        #expect(snapshot.spending.first?.used == 12.5)
        #expect(snapshot.spending.first?.limit == nil)
        #expect(snapshot.extraWindows.isEmpty)
    }

    @Test func cursorRetainsFourthWindowWithoutExhaustingIncludedQuota() throws {
        let snapshot = try CursorProvider().parseCurrentPeriodUsageForTesting([
            "membershipType": "pro",
            "planUsage": ["limit": 2000, "totalSpend": 1000, "totalPercentUsed": 50, "autoPercentUsed": 20, "apiPercentUsed": 30],
            "spendLimitUsage": ["enabled": true, "individualLimit": 1000, "individualUsed": 1000]
        ])
        #expect(snapshot.extraWindows.first?.label == "On-demand")
        #expect(snapshot.spending.count == 2)
        #expect(!snapshot.hasExhaustedQuota)
        #expect(AccountCardStatusPresenter.quotaLimitingMetrics(tool: .cursor, quota: snapshot).count == 3)
    }

    @Test func spendSurvivesCacheAndSnapshotReplacement() throws {
        let snapshot = QuotaSnapshot(source: "Claude Code OAuth", primary: nil, secondary: nil, creditsRemaining: nil, creditsTotal: nil, spending: [.init(label: "Extra usage", used: 3, limit: nil, currency: "USD", resetAt: nil)], updatedAt: Date(), note: nil)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.spending == snapshot.spending)
        #expect(decoded.replacing(source: "Cache").spending == snapshot.spending)
    }
}

extension ProviderQuotaCompletenessTests {
    @Test func freshOAuthCanClearSpendWhileLocalStatusRetainsIt() {
        let now = Date()
        let historical = QuotaSnapshot(source: "Claude Code OAuth", primary: nil, secondary: nil, creditsRemaining: nil, creditsTotal: nil, spending: [.init(label: "Extra usage", used: 3, limit: 5, currency: "USD", resetAt: nil)], updatedAt: now.addingTimeInterval(-60), note: nil)
        let fresh = QuotaSnapshot(source: "Claude Code OAuth", primary: nil, secondary: nil, creditsRemaining: nil, creditsTotal: nil, updatedAt: now, note: nil)
        let provider = ClaudeCodeProvider()
        #expect(provider.mergeClaudeSnapshot(fresh, fillingMissingMetricsFrom: historical).spending.isEmpty)
        let merged = provider.mergeClaudeSnapshot(fresh.replacing(source: "Claude Code StatusLine"), fillingMissingMetricsFrom: historical)
        #expect(merged.spending == historical.spending)
        #expect(merged.updatedAt == historical.updatedAt)
    }
}
