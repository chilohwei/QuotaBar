import Foundation

struct CursorProvider: Provider {
    let tool: ToolKind = .cursor
    let fileService = FileService()
    let apiBaseURL = URL(string: "https://api2.cursor.sh")!
    static let cycleBoundaryDateKeys: Set<String> = [
        "billingCycleEnd",
        "billing_cycle_end",
        "billingCycleEndAt",
        "billing_cycle_end_at",
        "currentPeriodEnd",
        "current_period_end",
        "currentPeriodEndAt",
        "current_period_end_at",
        "subscriptionCurrentPeriodEnd",
        "subscription_current_period_end",
        "subscriptionPeriodEnd",
        "subscription_period_end",
        "stripeCurrentPeriodEnd",
        "stripe_current_period_end",
        "periodEnd",
        "period_end",
        "cycleEnd",
        "cycle_end",
        "subscriptionExpiresAt",
        "subscription_expires_at",
        "nextBillingDate",
        "next_billing_date",
        "nextBillingAt",
        "next_billing_at",
        "renewalDate",
        "renewal_date",
        "resetAt",
        "reset_at",
        "resetAtMs",
        "reset_at_ms",
        "nextResetAt",
        "next_reset_at",
        "nextResetAtMs",
        "next_reset_at_ms"
    ]

    static let fallbackQuotaCacheAge: TimeInterval = 24 * 60 * 60
    static let maxNetworkAttempts = 3
    static let httpClient = QuotaHTTPClient(maxAttempts: maxNetworkAttempts)
    static let includedUsageKeys: Set<String> = [
        "planUsage",
        "plan_usage",
        "includedUsage",
        "included_usage",
        "included",
        "includedQuota",
        "included_quota",
        "quotaUsage",
        "quota_usage",
        "plan"
    ]
    static let onDemandUsageKeys: Set<String> = [
        "onDemand",
        "on_demand",
        "spendLimitUsage",
        "spend_limit_usage",
        "usageBased",
        "usage_based",
        "usageBasedPremiumRequests",
        "usage_based_premium_requests",
        "hardLimitUsage",
        "hard_limit_usage",
        "hardLimit",
        "hard_limit"
    ]
    static let usedAmountKeys: Set<String> = [
        "used",
        "usage",
        "usageCents",
        "usage_cents",
        "usedCents",
        "used_cents",
        "usedAmount",
        "used_amount",
        "amountUsed",
        "amount_used",
        "totalUsed",
        "total_used",
        "totalSpend",
        "total_spend",
        "includedSpend",
        "included_spend",
        "spent",
        "consumed",
        "currentUsage",
        "current_usage",
        "valueUsed",
        "value_used"
    ]
    static let limitAmountKeys: Set<String> = [
        "limit",
        "max",
        "quota",
        "total",
        "capacity",
        "includedAmountCents",
        "included_amount_cents",
        "includedLimit",
        "included_limit",
        "includedLimitCents",
        "included_limit_cents",
        "limitCents",
        "limit_cents",
        "totalCents",
        "total_cents",
        "amountLimit",
        "amount_limit",
        "maxAmount",
        "max_amount",
        "spendLimit",
        "spend_limit",
        "hardLimit",
        "hard_limit",
        "hardLimitCents",
        "hard_limit_cents",
        "valueLimit",
        "value_limit"
    ]
    static let remainingAmountKeys: Set<String> = [
        "remaining",
        "left",
        "available",
        "totalRemaining",
        "total_remaining",
        "remainingAmount",
        "remaining_amount",
        "remainingCents",
        "remaining_cents",
        "availableAmount",
        "available_amount",
        "valueRemaining",
        "value_remaining"
    ]
    static let percentUsedKeys: Set<String> = [
        "usedPercent",
        "used_percent",
        "percentUsed",
        "percent_used",
        "usagePercent",
        "usage_percent"
    ]
    static let windowLabelKeys: Set<String> = [
        "label",
        "name",
        "type",
        "kind",
        "bucket",
        "category",
        "feature",
        "metric",
        "window"
    ]

    struct CursorCredentials: Codable {
        let accessToken: String
        let refreshToken: String?
        let email: String?
        let membershipType: String?
        let subscriptionStatus: String?
        let subscriptionPeriodEnd: Date?
        let stateDatabasePath: String?
        let source: String?
    }

    struct CursorTokenRefreshResponse: Decodable {
        let accessToken: String?
        let idToken: String?
        let shouldLogout: Bool?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case idToken = "id_token"
            case shouldLogout
        }
    }

    struct CachedQuotaSnapshot: Codable {
        let schemaVersion: Int
        let cachedAt: Date
        let snapshot: QuotaSnapshot
    }

    struct CursorStateSnapshot {
        let directoryPath: String
        let databasePath: String
    }

    struct CursorStateCandidate {
        let path: String
        let modifiedAt: Date
    }

}
