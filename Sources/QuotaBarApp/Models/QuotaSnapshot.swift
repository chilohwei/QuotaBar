import Foundation

struct QuotaWindow: Codable, Equatable, Sendable {
    let label: String
    let used: Double
    let limit: Double
    let resetAt: Date?

    var remaining: Double {
        max(limit - used, 0)
    }

    var usagePercent: Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    var remainingPercent: Double {
        max(0, 1 - usagePercent) * 100
    }
}

enum QuotaDisplayMetric: Equatable, Sendable {
    case window(QuotaWindow)
    case credits(remaining: Double, total: Double, periodEnd: Date?)

    var title: String {
        switch self {
        case .window(let window):
            return window.label
        case .credits:
            return "Credits"
        }
    }

    var ratio: Double? {
        switch self {
        case .window(let window):
            guard window.limit > 0 else { return nil }
            return min(max(window.remaining / window.limit, 0), 1)
        case .credits(let remaining, let total, _):
            guard total > 0 else { return nil }
            return min(max(remaining / total, 0), 1)
        }
    }

    var resetAt: Date? {
        switch self {
        case .window(let window):
            return window.resetAt
        case .credits(_, _, let periodEnd):
            return periodEnd
        }
    }

    var window: QuotaWindow {
        switch self {
        case .window(let window):
            return window
        case .credits(let remaining, let total, let periodEnd):
            return QuotaWindow(
                label: "Credits",
                used: max(total - remaining, 0),
                limit: total,
                resetAt: periodEnd
            )
        }
    }
}

enum QuotaAvailabilityStatus: String, Codable, Equatable, Sendable {
    case normal
    case quotaExhausted
    case sessionRateLimited
    case authRateLimited
    case serviceUnavailable
}

struct QuotaSnapshot: Codable, Equatable, Sendable {
    let source: String
    let accountIdentifier: String?
    let planName: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    let tertiary: QuotaWindow?
    let extraWindows: [QuotaWindow]
    let creditsRemaining: Double?
    let creditsTotal: Double?
    let updatedAt: Date
    let periodEnd: Date?
    let accountValidUntil: Date?
    let subscriptionWillRenew: Bool?
    let subscriptionStatus: String?
    let isQuotaBlocked: Bool?
    let availabilityStatus: QuotaAvailabilityStatus?
    let note: String?

    init(
        source: String,
        accountIdentifier: String? = nil,
        planName: String? = nil,
        primary: QuotaWindow?,
        secondary: QuotaWindow?,
        tertiary: QuotaWindow? = nil,
        extraWindows: [QuotaWindow] = [],
        creditsRemaining: Double?,
        creditsTotal: Double?,
        updatedAt: Date,
        periodEnd: Date? = nil,
        accountValidUntil: Date? = nil,
        subscriptionWillRenew: Bool? = nil,
        subscriptionStatus: String? = nil,
        isQuotaBlocked: Bool? = nil,
        availabilityStatus: QuotaAvailabilityStatus? = nil,
        note: String?
    ) {
        self.source = source
        self.accountIdentifier = accountIdentifier
        self.planName = planName
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.extraWindows = extraWindows
        self.creditsRemaining = creditsRemaining
        self.creditsTotal = creditsTotal
        self.updatedAt = updatedAt
        self.periodEnd = periodEnd ?? ([primary?.resetAt, secondary?.resetAt, tertiary?.resetAt]
            + extraWindows.map(\.resetAt))
            .compactMap { $0 }
            .max()
        self.accountValidUntil = accountValidUntil
        self.subscriptionWillRenew = subscriptionWillRenew
        self.subscriptionStatus = subscriptionStatus
        self.isQuotaBlocked = isQuotaBlocked
        self.availabilityStatus = availabilityStatus
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try container.decode(String.self, forKey: .source),
            accountIdentifier: try container.decodeIfPresent(String.self, forKey: .accountIdentifier),
            planName: try container.decodeIfPresent(String.self, forKey: .planName),
            primary: try container.decodeIfPresent(QuotaWindow.self, forKey: .primary),
            secondary: try container.decodeIfPresent(QuotaWindow.self, forKey: .secondary),
            tertiary: try container.decodeIfPresent(QuotaWindow.self, forKey: .tertiary),
            extraWindows: try container.decodeIfPresent([QuotaWindow].self, forKey: .extraWindows) ?? [],
            creditsRemaining: try container.decodeIfPresent(Double.self, forKey: .creditsRemaining),
            creditsTotal: try container.decodeIfPresent(Double.self, forKey: .creditsTotal),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            periodEnd: try container.decodeIfPresent(Date.self, forKey: .periodEnd),
            accountValidUntil: try container.decodeIfPresent(Date.self, forKey: .accountValidUntil),
            subscriptionWillRenew: try container.decodeIfPresent(Bool.self, forKey: .subscriptionWillRenew),
            subscriptionStatus: try container.decodeIfPresent(String.self, forKey: .subscriptionStatus),
            isQuotaBlocked: try container.decodeIfPresent(Bool.self, forKey: .isQuotaBlocked),
            availabilityStatus: try container.decodeIfPresent(QuotaAvailabilityStatus.self, forKey: .availabilityStatus),
            note: try container.decodeIfPresent(String.self, forKey: .note)
        )
    }

    var effectiveAvailabilityStatus: QuotaAvailabilityStatus {
        if let availabilityStatus {
            return availabilityStatus
        }
        if note == QuotaNoteCatalog.claudeRateLimitReached {
            return .sessionRateLimited
        }
        if note == QuotaNoteCatalog.claudeUsageRateLimited {
            return .authRateLimited
        }
        if hasExhaustedQuota {
            return .quotaExhausted
        }
        return .normal
    }

    var isTemporarilyBlocked: Bool {
        effectiveAvailabilityStatus == .sessionRateLimited
            || effectiveAvailabilityStatus == .authRateLimited
            || effectiveAvailabilityStatus == .serviceUnavailable
    }

    var hasExhaustedQuota: Bool {
        orderedMetrics
            .compactMap(\.ratio)
            .contains { $0 <= 0.001 }
            || isQuotaBlocked == true
    }

    var statusBarMetric: QuotaDisplayMetric? {
        orderedMetrics.min { lhs, rhs in
            (lhs.ratio ?? .infinity) < (rhs.ratio ?? .infinity)
        }
    }

    var orderedMetrics: [QuotaDisplayMetric] {
        var items: [QuotaDisplayMetric] = []
        if let primary, primary.limit > 0 {
            items.append(.window(primary))
        }
        if let secondary, secondary.limit > 0 {
            items.append(.window(secondary))
        }
        if let tertiary, tertiary.limit > 0 {
            items.append(.window(tertiary))
        }
        if let creditsRemaining, let creditsTotal, creditsTotal > 0 {
            items.append(.credits(remaining: creditsRemaining, total: creditsTotal, periodEnd: periodEnd))
        }
        items.append(contentsOf: extraWindows.filter { $0.limit > 0 }.map(QuotaDisplayMetric.window))
        return items
    }

    /// Drops quota windows whose reset time has already passed: their counters have
    /// rolled over server-side, so the recorded used/remaining values no longer
    /// describe anything real. Exhaustion flags derived from a dropped window are
    /// cleared along with it.
    func removingExpiredWindows(now: Date = Date()) -> QuotaSnapshot {
        func active(_ window: QuotaWindow?) -> QuotaWindow? {
            guard let window else { return nil }
            guard let resetAt = window.resetAt else { return window }
            return resetAt.addingTimeInterval(QuotaFreshness.expiredResetGrace) < now ? nil : window
        }

        let activePrimary = active(primary)
        let activeSecondary = active(secondary)
        let activeTertiary = active(tertiary)
        let activeExtraWindows = extraWindows.compactMap(active)
        guard activePrimary != primary
            || activeSecondary != secondary
            || activeTertiary != tertiary
            || activeExtraWindows != extraWindows else {
            return self
        }

        let remainingWindowsExhausted = ([activePrimary, activeSecondary, activeTertiary].compactMap { $0 } + activeExtraWindows)
            .contains { $0.limit > 0 && $0.remaining / $0.limit <= 0.001 }
        let prunedBlocked = remainingWindowsExhausted ? isQuotaBlocked : nil
        let prunedAvailability = (availabilityStatus == .quotaExhausted && !remainingWindowsExhausted)
            ? nil
            : availabilityStatus

        return QuotaSnapshot(
            source: source,
            accountIdentifier: accountIdentifier,
            planName: planName,
            primary: activePrimary,
            secondary: activeSecondary,
            tertiary: activeTertiary,
            extraWindows: activeExtraWindows,
            creditsRemaining: creditsRemaining,
            creditsTotal: creditsTotal,
            updatedAt: updatedAt,
            periodEnd: periodEnd,
            accountValidUntil: accountValidUntil,
            subscriptionWillRenew: subscriptionWillRenew,
            subscriptionStatus: subscriptionStatus,
            isQuotaBlocked: prunedBlocked,
            availabilityStatus: prunedAvailability,
            note: note
        )
    }

    func replacing(
        source: String? = nil,
        updatedAt: Date? = nil,
        note: String? = nil,
        availabilityStatus: QuotaAvailabilityStatus? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            source: source ?? self.source,
            accountIdentifier: accountIdentifier,
            planName: planName,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraWindows: extraWindows,
            creditsRemaining: creditsRemaining,
            creditsTotal: creditsTotal,
            updatedAt: updatedAt ?? self.updatedAt,
            periodEnd: periodEnd,
            accountValidUntil: accountValidUntil,
            subscriptionWillRenew: subscriptionWillRenew,
            subscriptionStatus: subscriptionStatus,
            isQuotaBlocked: isQuotaBlocked,
            availabilityStatus: availabilityStatus ?? self.availabilityStatus,
            note: note ?? self.note
        )
    }
}
