import Foundation

enum AccountRecommendationStrategy: String, CaseIterable, Identifiable, Sendable {
    case preventWaste
    case maximizeAvailability

    var id: String { rawValue }
}

struct AccountListPresenter {
    private enum RecommendationPolicy {
        static let expiringSoonInterval: TimeInterval = 30 * 24 * 60 * 60
        static let deadlineBucketInterval: TimeInterval = 60 * 60
    }

    static func visibleAccounts(
        accounts: [Account],
        filter: AccountFilter,
        activeID: UUID?,
        quotaByAccount: [UUID: QuotaSnapshot],
        loadStateByAccount: [UUID: AccountLoadState],
        frozenOrder: [UUID]?,
        recommendationStrategy: AccountRecommendationStrategy = .preventWaste
    ) -> [Account] {
        let sortedAccounts = sortedForStableDisplay(
            accounts,
            activeID: activeID,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: loadStateByAccount,
            frozenOrder: frozenOrder,
            recommendationStrategy: recommendationStrategy
        )

        switch filter {
        case .all:
            return sortedAccounts
        case .available:
            return sortedAccounts.filter { isAccountAvailable($0, quotaByAccount: quotaByAccount) }
        }
    }

    static func availableAccountCount(
        accounts: [Account],
        quotaByAccount: [UUID: QuotaSnapshot]
    ) -> Int {
        accounts.filter { isAccountAvailable($0, quotaByAccount: quotaByAccount) }.count
    }

    static func recommendedAccountID(
        accounts: [Account],
        activeID: UUID?,
        quotaByAccount: [UUID: QuotaSnapshot],
        loadStateByAccount: [UUID: AccountLoadState],
        recommendationStrategy: AccountRecommendationStrategy = .preventWaste
    ) -> UUID? {
        let entries = sortEntries(
            accounts,
            activeID: activeID,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: loadStateByAccount,
            frozenOrder: nil
        )
        return entries
            .filter(\.isAvailable)
            .filter { $0.dataQualityRank != .failed && $0.dataQualityRank != .unknown }
            .sorted {
                recommendationPrecedes($0, $1, strategy: recommendationStrategy)
            }
            .first?
            .account
            .id
    }

    static func recommendationReasonStrategy(
        for account: Account,
        quotaByAccount: [UUID: QuotaSnapshot],
        recommendationStrategy: AccountRecommendationStrategy
    ) -> AccountRecommendationStrategy {
        guard recommendationStrategy == .preventWaste else {
            return .maximizeAvailability
        }

        let wasteDeadline = wasteDeadlineDate(account, quotaByAccount: quotaByAccount)
        let snapshotUpdatedAt = snapshotUpdatedAtDate(account, quotaByAccount: quotaByAccount)
        let secondsUntilDeadline = secondsUntilWasteDeadline(
            wasteDeadline: wasteDeadline,
            snapshotUpdatedAt: snapshotUpdatedAt
        )
        return isWasteDeadlineCandidate(secondsUntilDeadline) ? .preventWaste : .maximizeAvailability
    }

    static func isAccountAvailable(
        _ account: Account,
        quotaByAccount: [UUID: QuotaSnapshot]
    ) -> Bool {
        guard let quota = quotaByAccount[account.id] else {
            return false
        }

        switch quota.effectiveAvailabilityStatus {
        case .quotaExhausted, .sessionRateLimited:
            return false
        case .normal, .authRateLimited, .serviceUnavailable:
            break
        }

        let ratios = [quota.primary, quota.secondary, quota.tertiary]
            .compactMap { window -> Double? in
                guard let window, window.limit > 0 else { return nil }
                return min(max(window.remaining / window.limit, 0), 1)
            }
        if !ratios.isEmpty {
            return ratios.allSatisfy { Int(($0 * 100).rounded()) > 0 }
        }

        if account.tool == .claudeCode {
            let note = quota.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !quota.orderedMetrics.isEmpty
                || !note.isEmpty
                || quota.accountIdentifier?.isEmpty == false
        }

        if let remaining = quota.creditsRemaining {
            return remaining > 0
        }

        return false
    }

    private static func sortedForStableDisplay(
        _ accounts: [Account],
        activeID: UUID?,
        quotaByAccount: [UUID: QuotaSnapshot],
        loadStateByAccount: [UUID: AccountLoadState],
        frozenOrder: [UUID]?,
        recommendationStrategy: AccountRecommendationStrategy
    ) -> [Account] {
        let entries = sortEntries(
            accounts,
            activeID: activeID,
            quotaByAccount: quotaByAccount,
            loadStateByAccount: loadStateByAccount,
            frozenOrder: frozenOrder
        )
        let isRefreshing = accounts.contains { account in
            loadStateByAccount[account.id] == .refreshing
                || loadStateByAccount[account.id] == .loadingInitial
        }
        return entries.sorted { lhs, rhs in
            if frozenOrder != nil {
                let lhsRank = lhs.frozenRank ?? Int.max
                let rhsRank = rhs.frozenRank ?? Int.max
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
            }

            if isRefreshing {
                return lhs.account.createdAt < rhs.account.createdAt
            }

            if lhs.isActive != rhs.isActive {
                return lhs.isActive
            }

            return recommendationPrecedes(lhs, rhs, strategy: recommendationStrategy)
        }.map(\.account)
    }

    private static func sortEntries(
        _ accounts: [Account],
        activeID: UUID?,
        quotaByAccount: [UUID: QuotaSnapshot],
        loadStateByAccount: [UUID: AccountLoadState],
        frozenOrder: [UUID]?
    ) -> [SortEntry] {
        let frozenRankByID = Dictionary(
            uniqueKeysWithValues: (frozenOrder ?? []).enumerated().map { ($0.element, $0.offset) }
        )
        let entries = accounts.map { account in
            let bottleneckRatio = bottleneckRemainingRatio(account, quotaByAccount: quotaByAccount)
            let wasteDeadline = wasteDeadlineDate(account, quotaByAccount: quotaByAccount)
            let snapshotUpdatedAt = snapshotUpdatedAtDate(account, quotaByAccount: quotaByAccount)
            let secondsUntilWasteDeadline = secondsUntilWasteDeadline(
                wasteDeadline: wasteDeadline,
                snapshotUpdatedAt: snapshotUpdatedAt
            )
            return SortEntry(
                account: account,
                isActive: account.id == activeID,
                frozenRank: frozenRankByID[account.id],
                isAvailable: isAccountAvailable(account, quotaByAccount: quotaByAccount),
                availabilityRank: availabilityRank(
                    account,
                    quotaByAccount: quotaByAccount,
                    loadStateByAccount: loadStateByAccount
                ),
                dataQualityRank: dataQualityRank(
                    account,
                    quotaByAccount: quotaByAccount,
                    loadStateByAccount: loadStateByAccount
                ),
                bottleneckRatio: bottleneckRatio,
                earliestReset: earliestResetDate(account, quotaByAccount: quotaByAccount),
                wasteDeadline: wasteDeadline,
                secondsUntilWasteDeadline: secondsUntilWasteDeadline,
                snapshotUpdatedAt: snapshotUpdatedAt
            )
        }

        return entries
    }

    private static func recommendationPrecedes(
        _ lhs: SortEntry,
        _ rhs: SortEntry,
        strategy: AccountRecommendationStrategy
    ) -> Bool {
        if lhs.isAvailable != rhs.isAvailable {
            return lhs.isAvailable
        }

        if lhs.availabilityRank != rhs.availabilityRank {
            return lhs.availabilityRank < rhs.availabilityRank
        }

        if lhs.isAvailable {
            if lhs.dataQualityRank != rhs.dataQualityRank {
                return lhs.dataQualityRank < rhs.dataQualityRank
            }

            switch strategy {
            case .preventWaste:
                if let decision = wasteDeadlineDecision(lhs, rhs) {
                    return decision
                }
            case .maximizeAvailability:
                break
            }

            return availabilityDecision(lhs, rhs)
        } else if lhs.earliestReset != rhs.earliestReset {
            return lhs.earliestReset < rhs.earliestReset
        }

        if lhs.snapshotUpdatedAt != rhs.snapshotUpdatedAt {
            return lhs.snapshotUpdatedAt > rhs.snapshotUpdatedAt
        }

        return lhs.account.createdAt < rhs.account.createdAt
    }

    private static func wasteDeadlineDecision(_ lhs: SortEntry, _ rhs: SortEntry) -> Bool? {
        if lhs.isWasteDeadlineCandidate != rhs.isWasteDeadlineCandidate {
            return lhs.isWasteDeadlineCandidate
        }

        guard lhs.isWasteDeadlineCandidate, rhs.isWasteDeadlineCandidate else {
            return nil
        }

        let lhsBucket = wasteDeadlineBucket(lhs.secondsUntilWasteDeadline)
        let rhsBucket = wasteDeadlineBucket(rhs.secondsUntilWasteDeadline)
        if lhsBucket != rhsBucket {
            return lhsBucket < rhsBucket
        }

        if lhs.isActive != rhs.isActive {
            return lhs.isActive
        }

        let lhsRemainingBucket = remainingBucket(lhs.bottleneckRatio)
        let rhsRemainingBucket = remainingBucket(rhs.bottleneckRatio)
        if lhsRemainingBucket != rhsRemainingBucket {
            return lhsRemainingBucket > rhsRemainingBucket
        }

        if lhs.bottleneckRatio != rhs.bottleneckRatio {
            return lhs.bottleneckRatio > rhs.bottleneckRatio
        }

        if lhs.wasteDeadline != rhs.wasteDeadline {
            return lhs.wasteDeadline < rhs.wasteDeadline
        }

        return nil
    }

    private static func availabilityDecision(_ lhs: SortEntry, _ rhs: SortEntry) -> Bool {
        let lhsBucket = remainingBucket(lhs.bottleneckRatio)
        let rhsBucket = remainingBucket(rhs.bottleneckRatio)
        if lhsBucket != rhsBucket {
            return lhsBucket > rhsBucket
        }

        if lhs.isActive != rhs.isActive {
            return lhs.isActive
        }

        if lhs.bottleneckRatio != rhs.bottleneckRatio {
            return lhs.bottleneckRatio > rhs.bottleneckRatio
        }

        if lhs.wasteDeadline != rhs.wasteDeadline {
            return lhs.wasteDeadline < rhs.wasteDeadline
        }

        if lhs.snapshotUpdatedAt != rhs.snapshotUpdatedAt {
            return lhs.snapshotUpdatedAt > rhs.snapshotUpdatedAt
        }

        return lhs.account.createdAt < rhs.account.createdAt
    }

    private static func wasteDeadlineDate(
        _ account: Account,
        quotaByAccount: [UUID: QuotaSnapshot]
    ) -> Date {
        guard let quota = quotaByAccount[account.id] else { return .distantFuture }

        var dates = quota.orderedMetrics.compactMap { metric -> Date? in
            guard let ratio = metric.ratio, ratio > 0.001 else { return nil }
            return metric.resetAt
        }
        if let accountValidUntil = quota.accountValidUntil {
            dates.append(accountValidUntil)
        }
        return dates.min() ?? .distantFuture
    }

    private static func secondsUntilWasteDeadline(
        wasteDeadline: Date,
        snapshotUpdatedAt: Date
    ) -> TimeInterval {
        guard wasteDeadline != .distantFuture else { return .infinity }
        let reference = snapshotUpdatedAt == .distantPast ? Date() : snapshotUpdatedAt
        return wasteDeadline.timeIntervalSince(reference)
    }

    private static func wasteDeadlineBucket(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return Int.max }
        return Int((seconds / RecommendationPolicy.deadlineBucketInterval).rounded(.down))
    }

    private static func isWasteDeadlineCandidate(_ seconds: TimeInterval) -> Bool {
        guard seconds.isFinite, seconds > 0 else { return false }
        return seconds <= RecommendationPolicy.expiringSoonInterval
    }

    private static func remainingBucket(_ ratio: Double) -> Int {
        guard ratio >= 0 else { return -1 }
        return Int((min(max(ratio, 0), 1) * 20).rounded(.down))
    }

    private static func availabilityRank(
        _ account: Account,
        quotaByAccount: [UUID: QuotaSnapshot],
        loadStateByAccount: [UUID: AccountLoadState]
    ) -> AvailabilityRank {
        guard let quota = quotaByAccount[account.id] else {
            return loadStateByAccount[account.id] == .failed ? .failed : .unknown
        }

        if isAccountAvailable(account, quotaByAccount: quotaByAccount) {
            return .available
        }

        switch quota.effectiveAvailabilityStatus {
        case .sessionRateLimited:
            return .blocked
        case .quotaExhausted:
            if earliestResetDate(account, quotaByAccount: quotaByAccount) != .distantFuture {
                return .recovering
            }
            return .exhausted
        case .authRateLimited, .serviceUnavailable:
            return .failed
        case .normal:
            break
        }

        if earliestResetDate(account, quotaByAccount: quotaByAccount) != .distantFuture {
            return .recovering
        }

        if !quota.orderedMetrics.isEmpty {
            return .exhausted
        }

        let loadState = loadStateByAccount[account.id]
        if loadState == .failed || loadState == .stale {
            return .failed
        }
        return .unknown
    }

    private static func dataQualityRank(
        _ account: Account,
        quotaByAccount: [UUID: QuotaSnapshot],
        loadStateByAccount: [UUID: AccountLoadState]
    ) -> DataQualityRank {
        let hasQuota = quotaByAccount[account.id] != nil
        switch loadStateByAccount[account.id] {
        case .loaded:
            return .fresh
        case .refreshing:
            return hasQuota ? .refreshingWithData : .loading
        case .loadingInitial:
            return .loading
        case .stale:
            return hasQuota ? .stale : .failed
        case .failed:
            return .failed
        case .idle, .none:
            return hasQuota ? .fresh : .unknown
        }
    }

    private static func bottleneckRemainingRatio(
        _ account: Account,
        quotaByAccount: [UUID: QuotaSnapshot]
    ) -> Double {
        guard let quota = quotaByAccount[account.id] else { return -1 }
        let ratios = quota.orderedMetrics.compactMap(\.ratio)
        return ratios.min() ?? -1
    }

    private static func earliestResetDate(
        _ account: Account,
        quotaByAccount: [UUID: QuotaSnapshot]
    ) -> Date {
        guard let quota = quotaByAccount[account.id] else { return .distantFuture }
        return quota.orderedMetrics.compactMap(\.resetAt).min() ?? .distantFuture
    }

    private static func snapshotUpdatedAtDate(
        _ account: Account,
        quotaByAccount: [UUID: QuotaSnapshot]
    ) -> Date {
        quotaByAccount[account.id]?.updatedAt ?? .distantPast
    }

    private struct SortEntry {
        let account: Account
        let isActive: Bool
        let frozenRank: Int?
        let isAvailable: Bool
        let availabilityRank: AvailabilityRank
        let dataQualityRank: DataQualityRank
        let bottleneckRatio: Double
        let earliestReset: Date
        let wasteDeadline: Date
        let secondsUntilWasteDeadline: TimeInterval
        let snapshotUpdatedAt: Date

        var isWasteDeadlineCandidate: Bool {
            AccountListPresenter.isWasteDeadlineCandidate(secondsUntilWasteDeadline)
        }
    }

    private enum AvailabilityRank: Int, Comparable {
        case available = 0
        case recovering = 1
        case exhausted = 2
        case blocked = 3
        case failed = 4
        case unknown = 5

        static func < (lhs: AvailabilityRank, rhs: AvailabilityRank) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private enum DataQualityRank: Int, Comparable {
        case fresh = 0
        case refreshingWithData = 1
        case stale = 2
        case loading = 3
        case failed = 4
        case unknown = 5

        static func < (lhs: DataQualityRank, rhs: DataQualityRank) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}

enum AccountFilter {
    case all
    case available
}
