import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Account list presenter")
struct AccountListPresenterTests {
    @Test("available filter removes exhausted account")
    func availableFilter() {
        let available = Account(id: UUID(), tool: .codex, name: "available", createdAt: Date(timeIntervalSince1970: 1))
        let exhausted = Account(id: UUID(), tool: .codex, name: "exhausted", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            available.id: snapshot(remaining: 80),
            exhausted.id: snapshot(remaining: 0)
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [exhausted, available],
            filter: .available,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.map(\.id) == [available.id])
    }

    @Test("available filter removes accounts whose displayed remaining percent is zero")
    func availableFilterUsesDisplayedZeroPercent() {
        let nearlyExhausted = Account(id: UUID(), tool: .codex, name: "near-zero", createdAt: Date(timeIntervalSince1970: 1))
        let quotaByAccount = [
            nearlyExhausted.id: snapshot(remaining: 0.4)
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [nearlyExhausted],
            filter: .available,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.isEmpty)
    }

    @Test("available filter removes account when any known window is exhausted")
    func availableFilterRequiresEveryKnownWindow() {
        let account = Account(id: UUID(), tool: .codex, name: "weekly-exhausted", createdAt: Date(timeIntervalSince1970: 1))
        let quotaByAccount = [
            account.id: QuotaSnapshot(
                source: "test",
                planName: "Plus",
                primary: QuotaWindow(label: "5h", used: 1, limit: 100, resetAt: nil),
                secondary: QuotaWindow(label: "Weekly", used: 100, limit: 100, resetAt: nil),
                creditsRemaining: nil,
                creditsTotal: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                note: nil
            )
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [account],
            filter: .available,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.isEmpty)
    }

    @Test("refresh rate limit does not hide otherwise available account")
    func refreshRateLimitDoesNotHideAvailableAccount() {
        let account = Account(id: UUID(), tool: .claudeCode, name: "claude", createdAt: Date(timeIntervalSince1970: 1))
        let quotaByAccount = [
            account.id: QuotaSnapshot(
                source: "Claude Code OAuth Cache",
                primary: QuotaWindow(label: "5h", used: 40, limit: 100, resetAt: nil),
                secondary: nil,
                creditsRemaining: nil,
                creditsTotal: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                availabilityStatus: .authRateLimited,
                note: QuotaNoteCatalog.claudeUsageRateLimited
            )
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [account],
            filter: .available,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.map(\.id) == [account.id])
    }

    @Test("session rate limit hides account without rewriting quota")
    func sessionRateLimitHidesAccountWithoutRewritingQuota() {
        let account = Account(id: UUID(), tool: .claudeCode, name: "claude", createdAt: Date(timeIntervalSince1970: 1))
        let quotaByAccount = [
            account.id: QuotaSnapshot(
                source: "Claude Code OAuth",
                primary: QuotaWindow(label: "5h", used: 40, limit: 100, resetAt: nil),
                secondary: nil,
                creditsRemaining: nil,
                creditsTotal: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                availabilityStatus: .sessionRateLimited,
                note: QuotaNoteCatalog.claudeRateLimitReached
            )
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [account],
            filter: .available,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.isEmpty)
        #expect(quotaByAccount[account.id]?.statusBarMetric?.ratio == 0.6)
    }

    @Test("active account stays first even when another account is recommended")
    func activeAccountStaysFirstEvenWhenAnotherAccountIsRecommended() {
        let recommended = Account(id: UUID(), tool: .codex, name: "recommended", createdAt: Date(timeIntervalSince1970: 1))
        let active = Account(id: UUID(), tool: .codex, name: "active", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            recommended.id: snapshot(remaining: 95),
            active.id: snapshot(remaining: 20)
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [recommended, active],
            filter: .all,
            activeID: active.id,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )
        let recommendedID = AccountListPresenter.recommendedAccountID(
            accounts: [recommended, active],
            activeID: active.id,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:]
        )

        #expect(result.first?.id == active.id)
        #expect(recommendedID == recommended.id)
    }

    @Test("recommended account falls back to more quota when no deadline is known")
    func recommendedAccountFallsBackToMoreQuotaWhenNoDeadlineIsKnown() {
        let lowQuota = Account(id: UUID(), tool: .codex, name: "low", createdAt: Date(timeIntervalSince1970: 1))
        let highQuota = Account(id: UUID(), tool: .codex, name: "high", createdAt: Date(timeIntervalSince1970: 2))
        let exhausted = Account(id: UUID(), tool: .codex, name: "exhausted", createdAt: Date(timeIntervalSince1970: 3))
        let quotaByAccount = [
            lowQuota.id: snapshot(remaining: 20),
            highQuota.id: snapshot(remaining: 80),
            exhausted.id: snapshot(remaining: 0)
        ]

        let recommended = AccountListPresenter.recommendedAccountID(
            accounts: [lowQuota, highQuota, exhausted],
            activeID: lowQuota.id,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:]
        )

        #expect(recommended == highQuota.id)
    }

    @Test("recommended account keeps active account when remaining quota is close")
    func recommendedAccountKeepsActiveWhenQuotaIsClose() {
        let active = Account(id: UUID(), tool: .codex, name: "active", createdAt: Date(timeIntervalSince1970: 1))
        let slightlyHigher = Account(id: UUID(), tool: .codex, name: "slightly-higher", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            active.id: snapshot(remaining: 80),
            slightlyHigher.id: snapshot(remaining: 83)
        ]

        let recommended = AccountListPresenter.recommendedAccountID(
            accounts: [slightlyHigher, active],
            activeID: active.id,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:]
        )

        #expect(recommended == active.id)
    }

    @Test("recommended account prefers quota window that resets soon")
    func recommendedAccountPrefersQuotaWindowThatResetsSoon() {
        let highButFar = Account(id: UUID(), tool: .codex, name: "high-far", createdAt: Date(timeIntervalSince1970: 1))
        let lowerButSoon = Account(id: UUID(), tool: .codex, name: "lower-soon", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            highButFar.id: snapshot(remaining: 90, resetAt: Date(timeIntervalSince1970: 4_000_000)),
            lowerButSoon.id: snapshot(remaining: 40, resetAt: Date(timeIntervalSince1970: 36_000))
        ]

        let recommended = AccountListPresenter.recommendedAccountID(
            accounts: [highButFar, lowerButSoon],
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:]
        )

        #expect(recommended == lowerButSoon.id)
    }

    @Test("recommended account prefers low remaining quota before it expires")
    func recommendedAccountPrefersLowRemainingQuotaBeforeItExpires() {
        let lowSoon = Account(id: UUID(), tool: .codex, name: "low-soon", createdAt: Date(timeIntervalSince1970: 1))
        let highLater = Account(id: UUID(), tool: .codex, name: "high-later", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            lowSoon.id: snapshot(remaining: 25, accountValidUntil: Date(timeIntervalSince1970: 36_000)),
            highLater.id: snapshot(remaining: 90, accountValidUntil: Date(timeIntervalSince1970: 4_000_000))
        ]

        let recommended = AccountListPresenter.recommendedAccountID(
            accounts: [lowSoon, highLater],
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:]
        )

        #expect(recommended == lowSoon.id)
    }

    @Test("maximize availability strategy keeps recommending the account with more quota")
    func maximizeAvailabilityStrategyKeepsRecommendingMoreQuota() {
        let lowSoon = Account(id: UUID(), tool: .codex, name: "low-soon", createdAt: Date(timeIntervalSince1970: 1))
        let highLater = Account(id: UUID(), tool: .codex, name: "high-later", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            lowSoon.id: snapshot(remaining: 25, accountValidUntil: Date(timeIntervalSince1970: 36_000)),
            highLater.id: snapshot(remaining: 90, accountValidUntil: Date(timeIntervalSince1970: 4_000_000))
        ]

        let recommended = AccountListPresenter.recommendedAccountID(
            accounts: [lowSoon, highLater],
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            recommendationStrategy: .maximizeAvailability
        )

        #expect(recommended == highLater.id)
    }

    @Test("recommended account prefers fresh data over stale cache")
    func recommendedAccountPrefersFreshDataOverStaleCache() {
        let staleHigh = Account(id: UUID(), tool: .codex, name: "stale-high", createdAt: Date(timeIntervalSince1970: 1))
        let freshLower = Account(id: UUID(), tool: .codex, name: "fresh-lower", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            staleHigh.id: snapshot(remaining: 95),
            freshLower.id: snapshot(remaining: 80)
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [staleHigh, freshLower],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [
                staleHigh.id: .stale,
                freshLower.id: .loaded
            ],
            frozenOrder: nil
        )

        let recommended = AccountListPresenter.recommendedAccountID(
            accounts: [staleHigh, freshLower],
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [
                staleHigh.id: .stale,
                freshLower.id: .loaded
            ]
        )

        #expect(result.first?.id == freshLower.id)
        #expect(recommended == freshLower.id)
    }

    @Test("fresh available account outranks stale failed and unknown data")
    func freshAvailableAccountOutranksUntrustedData() {
        let freshLower = Account(id: UUID(), tool: .codex, name: "fresh-lower", createdAt: Date(timeIntervalSince1970: 1))
        let staleCachedHigh = Account(id: UUID(), tool: .codex, name: "stale-cached-high", createdAt: Date(timeIntervalSince1970: 2))
        let failedCachedHigh = Account(id: UUID(), tool: .codex, name: "failed-cached-high", createdAt: Date(timeIntervalSince1970: 3))
        let unknown = Account(id: UUID(), tool: .codex, name: "unknown", createdAt: Date(timeIntervalSince1970: 4))
        let quotaByAccount = [
            freshLower.id: snapshot(remaining: 60),
            staleCachedHigh.id: snapshot(remaining: 95),
            failedCachedHigh.id: snapshot(remaining: 99)
        ]
        let loadStateByAccount: [UUID: AccountLoadState] = [
            freshLower.id: .loaded,
            staleCachedHigh.id: .stale,
            failedCachedHigh.id: .failed
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [unknown, failedCachedHigh, staleCachedHigh, freshLower],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: loadStateByAccount,
            frozenOrder: nil
        )
        let recommended = AccountListPresenter.recommendedAccountID(
            accounts: [unknown, failedCachedHigh, staleCachedHigh, freshLower],
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: loadStateByAccount
        )

        #expect(result.map(\.id) == [freshLower.id, staleCachedHigh.id, failedCachedHigh.id, unknown.id])
        #expect(recommended == freshLower.id)
    }

    @Test("available inactive accounts sort by bottleneck remaining ratio descending")
    func availableAccountsSortByBottleneckRemainingRatio() {
        let lowQuota = Account(id: UUID(), tool: .codex, name: "low", createdAt: Date(timeIntervalSince1970: 1))
        let highQuota = Account(id: UUID(), tool: .codex, name: "high", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            lowQuota.id: snapshot(remaining: 10),
            highQuota.id: snapshot(remaining: 95)
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [highQuota, lowQuota],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.map(\.id) == [highQuota.id, lowQuota.id])
    }

    @Test("all filter puts available accounts before unavailable accounts")
    func allFilterRanksAvailableBeforeUnavailable() {
        let exhausted = Account(id: UUID(), tool: .codex, name: "exhausted", createdAt: Date(timeIntervalSince1970: 1))
        let available = Account(id: UUID(), tool: .codex, name: "available", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            exhausted.id: snapshot(remaining: 0),
            available.id: snapshot(remaining: 30)
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [exhausted, available],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.map(\.id) == [available.id, exhausted.id])
    }

    @Test("unavailable accounts with earlier reset sort first")
    func unavailableAccountsSortByEarliestReset() {
        let later = Account(id: UUID(), tool: .codex, name: "later", createdAt: Date(timeIntervalSince1970: 1))
        let earlier = Account(id: UUID(), tool: .codex, name: "earlier", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            later.id: snapshot(remaining: 0, resetAt: Date(timeIntervalSince1970: 200)),
            earlier.id: snapshot(remaining: 0, resetAt: Date(timeIntervalSince1970: 100))
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [later, earlier],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.map(\.id) == [earlier.id, later.id])
    }

    @Test("cursor accounts use the same bottleneck quota ordering")
    func cursorAccountsUseBottleneckOrdering() {
        let lowWeekly = Account(id: UUID(), tool: .cursor, name: "low-weekly", createdAt: Date(timeIntervalSince1970: 1))
        let highWeekly = Account(id: UUID(), tool: .cursor, name: "high-weekly", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            lowWeekly.id: multiWindowSnapshot(primaryRemaining: 90, secondaryRemaining: 12),
            highWeekly.id: multiWindowSnapshot(primaryRemaining: 45, secondaryRemaining: 40)
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [lowWeekly, highWeekly],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.map(\.id) == [highWeekly.id, lowWeekly.id])
    }

    @Test("available accounts prioritize quota that resets soon")
    func availableAccountsPrioritizeQuotaThatResetsSoon() {
        let highButFar = Account(id: UUID(), tool: .codex, name: "high-far", createdAt: Date(timeIntervalSince1970: 1))
        let lowerButSoon = Account(id: UUID(), tool: .codex, name: "low-soon", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            highButFar.id: snapshot(remaining: 90, resetAt: Date(timeIntervalSince1970: 1_800_000)),
            lowerButSoon.id: snapshot(remaining: 40, resetAt: Date(timeIntervalSince1970: 36_000))
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [highButFar, lowerButSoon],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.map(\.id) == [lowerButSoon.id, highButFar.id])
    }

    @Test("near expiry account is prioritized even when little quota remains")
    func nearExpiryAccountIsPrioritizedEvenWhenLittleQuotaRemains() {
        let lowSoon = Account(id: UUID(), tool: .codex, name: "low-soon", createdAt: Date(timeIntervalSince1970: 1))
        let highLater = Account(id: UUID(), tool: .codex, name: "high-later", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            lowSoon.id: snapshot(remaining: 8, accountValidUntil: Date(timeIntervalSince1970: 36_000)),
            highLater.id: snapshot(remaining: 80, accountValidUntil: Date(timeIntervalSince1970: 1_800_000))
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [lowSoon, highLater],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.map(\.id) == [lowSoon.id, highLater.id])
    }

    @Test("available accounts with equal utilization fall back to freshest snapshot")
    func availableAccountsPreferFresherSnapshotsAsTieBreaker() {
        let stale = Account(id: UUID(), tool: .codex, name: "stale", createdAt: Date(timeIntervalSince1970: 1))
        let fresh = Account(id: UUID(), tool: .codex, name: "fresh", createdAt: Date(timeIntervalSince1970: 2))
        let commonExpiry = Date(timeIntervalSince1970: 86_400)
        let quotaByAccount = [
            stale.id: snapshot(
                remaining: 50,
                accountValidUntil: commonExpiry,
                updatedAt: Date(timeIntervalSince1970: 0)
            ),
            fresh.id: snapshot(
                remaining: 50,
                accountValidUntil: commonExpiry,
                updatedAt: Date(timeIntervalSince1970: 600)
            )
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [stale, fresh],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: nil
        )

        #expect(result.map(\.id) == [fresh.id, stale.id])
    }

    @Test("claude code unavailable accounts prioritize recoverable accounts")
    func claudeCodeUnavailableAccountsPrioritizeRecoverableAccounts() {
        let recoverable = Account(id: UUID(), tool: .claudeCode, name: "recoverable", createdAt: Date(timeIntervalSince1970: 1))
        let exhausted = Account(id: UUID(), tool: .claudeCode, name: "exhausted", createdAt: Date(timeIntervalSince1970: 2))
        let blocked = Account(id: UUID(), tool: .claudeCode, name: "blocked", createdAt: Date(timeIntervalSince1970: 3))
        let failed = Account(id: UUID(), tool: .claudeCode, name: "failed", createdAt: Date(timeIntervalSince1970: 4))
        let unknown = Account(id: UUID(), tool: .claudeCode, name: "unknown", createdAt: Date(timeIntervalSince1970: 5))
        let quotaByAccount = [
            recoverable.id: snapshot(remaining: 0, resetAt: Date(timeIntervalSince1970: 100)),
            exhausted.id: snapshot(remaining: 0),
            blocked.id: blockedSnapshot(),
            failed.id: emptySnapshot()
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [unknown, failed, blocked, exhausted, recoverable],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [failed.id: .failed],
            frozenOrder: nil
        )

        #expect(result.map(\.id) == [recoverable.id, exhausted.id, blocked.id, failed.id, unknown.id])
    }

    @Test("refreshing accounts keep frozen order")
    func refreshingKeepsFrozenOrder() {
        let lowQuota = Account(id: UUID(), tool: .codex, name: "low", createdAt: Date(timeIntervalSince1970: 1))
        let highQuota = Account(id: UUID(), tool: .codex, name: "high", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            lowQuota.id: snapshot(remaining: 10),
            highQuota.id: snapshot(remaining: 95)
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [highQuota, lowQuota],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [highQuota.id: .refreshing],
            frozenOrder: [lowQuota.id, highQuota.id]
        )

        #expect(result.map(\.id) == [lowQuota.id, highQuota.id])
    }

    @Test("frozen order is honored while refresh state is settling")
    func frozenOrderAppliesWithoutRefreshingState() {
        let lowQuota = Account(id: UUID(), tool: .codex, name: "low", createdAt: Date(timeIntervalSince1970: 1))
        let highQuota = Account(id: UUID(), tool: .codex, name: "high", createdAt: Date(timeIntervalSince1970: 2))
        let quotaByAccount = [
            lowQuota.id: snapshot(remaining: 10),
            highQuota.id: snapshot(remaining: 95)
        ]

        let result = AccountListPresenter.visibleAccounts(
            accounts: [highQuota, lowQuota],
            filter: .all,
            activeID: nil,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: [:],
            frozenOrder: [lowQuota.id, highQuota.id]
        )

        #expect(result.map(\.id) == [lowQuota.id, highQuota.id])
    }

    private func snapshot(
        remaining: Double,
        resetAt: Date? = nil,
        accountValidUntil: Date? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            source: "test",
            primary: QuotaWindow(label: "5h", used: 100 - remaining, limit: 100, resetAt: resetAt),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: updatedAt,
            accountValidUntil: accountValidUntil,
            note: nil
        )
    }

    private func multiWindowSnapshot(primaryRemaining: Double, secondaryRemaining: Double) -> QuotaSnapshot {
        QuotaSnapshot(
            source: "test",
            primary: QuotaWindow(label: "Fast", used: 100 - primaryRemaining, limit: 100, resetAt: nil),
            secondary: QuotaWindow(label: "Weekly", used: 100 - secondaryRemaining, limit: 100, resetAt: nil),
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            note: nil
        )
    }

    private func blockedSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(
            source: "test",
            primary: QuotaWindow(label: "5h", used: 0, limit: 100, resetAt: nil),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            isQuotaBlocked: true,
            note: nil
        )
    }

    private func emptySnapshot() -> QuotaSnapshot {
        QuotaSnapshot(
            source: "test",
            primary: nil,
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            note: nil
        )
    }
}
