import SwiftUI

enum AccountVisualStatus: Equatable {
    case healthy
    case refreshing
    case pending
    case noQuota
    case stale
    case warning
    case exhausted
    case error

    func title(_ text: AppText) -> String {
        switch self {
        case .healthy: return text.string(.normal)
        case .refreshing: return text.string(.refreshing)
        case .pending: return text.string(.pendingRefresh)
        case .noQuota: return text.string(.noQuota)
        case .stale: return text.string(.staleData)
        case .warning: return text.string(.nearLimit)
        case .exhausted: return text.string(.exhausted)
        case .error: return text.string(.error)
        }
    }

    var tint: Color {
        switch self {
        case .healthy: return Branding.success
        case .refreshing: return Branding.accentBlue
        case .pending, .noQuota: return Branding.inkMuted
        case .stale: return Branding.inkMuted
        case .warning: return Branding.warning
        case .exhausted, .error: return Branding.danger
        }
    }
}

enum AccountCardStatusPresenter {
    static let warningRemainingThreshold = 0.20
    static let exhaustedRemainingThreshold = 0.001

    static func status(
        tool: ToolKind,
        quota: QuotaSnapshot?,
        loadState: AccountLoadState,
        isRefreshing: Bool,
        errorMessage: String?,
        errorRequiresUserAction: Bool
    ) -> AccountVisualStatus {
        if errorMessage != nil, quota == nil {
            return errorRequiresUserAction ? .error : .pending
        }
        if isRefreshing || loadState == .refreshing || loadState == .loadingInitial {
            return .refreshing
        }
        guard let quota else { return .pending }
        if QuotaFreshness.isStale(quota) { return .stale }

        switch quota.effectiveAvailabilityStatus {
        case .quotaExhausted:
            return .exhausted
        case .sessionRateLimited, .authRateLimited, .serviceUnavailable:
            return .warning
        case .normal:
            break
        }

        let metrics = quota.orderedMetrics
        if metrics.isEmpty {
            return tool == .claudeCode ? .healthy : .noQuota
        }

        let limitingMetrics = quotaLimitingMetrics(tool: tool, quota: quota)
        let remainingRatios = limitingMetrics.compactMap(\.ratio)

        if remainingRatios.contains(where: { $0 <= exhaustedRemainingThreshold }) {
            return .exhausted
        }
        if tool == .claudeCode, limitingMetrics.isEmpty {
            return .healthy
        }

        let bottleneckRatio = remainingRatios.min()
        if remainingRatios.contains(where: { $0 > exhaustedRemainingThreshold }) {
            guard let bottleneckRatio else { return .healthy }
            return bottleneckRatio <= warningRemainingThreshold ? .warning : .healthy
        }

        guard let bottleneckRatio else { return .noQuota }
        if bottleneckRatio <= exhaustedRemainingThreshold { return .exhausted }
        if bottleneckRatio <= warningRemainingThreshold { return .warning }
        return .healthy
    }

    /// Detail line for a card whose metric strip has nothing to plot.
    ///
    /// A card-worthy note is already rendered in the footer, so repeating it under the
    /// empty tile printed the same sentence twice. Freshness notes, which the footer
    /// deliberately filters out, are still worth surfacing here.
    static func metricFallbackDetail(
        quota: QuotaSnapshot?,
        hasVisibleMetrics: Bool,
        text: AppText
    ) -> String? {
        guard !hasVisibleMetrics, let quota else { return nil }
        if text.shouldDisplayNoteOnCard(quota.note) { return nil }
        return text.localizedNote(quota.note)
    }

    // Claude Code reports informational windows beyond the ones that actually
    // gate usage; only primary/secondary/credits count toward availability.
    static func quotaLimitingMetrics(tool: ToolKind, quota: QuotaSnapshot?) -> [QuotaDisplayMetric] {
        guard let quota else { return [] }
        guard tool == .claudeCode else { return quota.orderedMetrics }

        var items: [QuotaDisplayMetric] = []
        if let primary = quota.primary {
            items.append(.window(primary))
        }
        if let secondary = quota.secondary {
            items.append(.window(secondary))
        }
        if let remaining = quota.creditsRemaining,
           let total = quota.creditsTotal,
           total > 0 {
            items.append(.credits(remaining: remaining, total: total, periodEnd: quota.periodEnd))
        }
        return items
    }
}
