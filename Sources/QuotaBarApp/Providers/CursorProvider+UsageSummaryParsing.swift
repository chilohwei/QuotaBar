import Foundation

extension CursorProvider {
    func parseUsageSummaryFallback(
        summary: Any,
        requestUsage: Any?,
        credentials: CursorCredentials,
        planName: String?
    ) throws -> QuotaSnapshot {
        guard let summaryDict = summary as? [String: Any] else {
            throw ProviderError.network("Cursor usage-summary 返回格式无效")
        }

        let requestDict = requestUsage as? [String: Any]
        let resolvedPlanName = normalizedPlanName(
            planName
                ?? firstString(in: summaryDict, keys: ["membershipType", "membership_type"])
                ?? credentials.membershipType
        )
        let periodEnd = firstDate(in: summaryDict, keys: Self.cycleBoundaryDateKeys)
            ?? firstDate(in: requestDict as Any, keys: Self.cycleBoundaryDateKeys)
        let accountIdentifier = cursorAccountIdentifier(from: summaryDict, credentials: credentials)

        var primary: QuotaWindow?
        var secondary: QuotaWindow?
        var tertiary: QuotaWindow?

        if let requestDict,
           let requests = requestDict["gpt-4"] as? [String: Any],
           let limit = directDouble(in: requests, keys: ["maxRequestUsage", "max_request_usage"]),
           limit > 0 {
            let used = directDouble(in: requests, keys: ["numRequests", "num_requests"])
                ?? directDouble(in: requests, keys: ["numRequestsTotal", "num_requests_total"])
                ?? 0
            primary = QuotaWindow(label: "Total", used: max(used, 0), limit: limit, resetAt: periodEnd)
        }

        if primary == nil {
            primary = parseUsageSummaryTotalWindow(from: summaryDict, resetAt: periodEnd)
        }

        let individual = summaryDict["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        let auto = parsePercentWindow(
            label: "Auto",
            usedPercent: plan.flatMap { planUsagePercent($0, key: "autoPercentUsed") },
            resetAt: periodEnd
        )
        let api = parsePercentWindow(
            label: "API",
            usedPercent: plan.flatMap { planUsagePercent($0, key: "apiPercentUsed") },
            resetAt: periodEnd
        )
        secondary = auto ?? api
        if let api, secondary?.label != api.label {
            tertiary = api
        }

        if tertiary == nil {
            tertiary = parseUsageSummaryOnDemandWindow(from: summaryDict, resetAt: periodEnd)
        }

        guard primary != nil || secondary != nil || tertiary != nil else {
            throw ProviderError.network("Cursor usage-summary 未返回可用额度字段")
        }

        return QuotaSnapshot(
            source: "Cursor Summary",
            accountIdentifier: accountIdentifier,
            planName: resolvedPlanName,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: .init(),
            periodEnd: periodEnd,
            accountValidUntil: credentials.subscriptionPeriodEnd,
            subscriptionWillRenew: inferSubscriptionWillRenew(from: credentials.subscriptionStatus),
            subscriptionStatus: normalizedSubscriptionStatus(credentials.subscriptionStatus),
            note: usageSummaryNote(from: summaryDict)
        )
    }

    func shouldUseUsageSummaryFallback(_ payload: Any, planName: String?) -> Bool {
        guard firstBool(in: payload, keys: ["enabled"]) != false else {
            return false
        }

        let plan = firstDictionary(in: payload, keys: Self.includedUsageKeys)
        let hasLimit = plan.flatMap { directDouble(in: $0, keys: Self.limitAmountKeys) } != nil
        let hasTotalPercent = plan.flatMap { planUsagePercent($0, key: "totalPercentUsed") } != nil
        let planUsageUnusable = plan == nil || (!hasLimit && !hasTotalPercent)

        let normalized = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if planUsageUnusable && (normalized == "enterprise" || normalized == "team") {
            return true
        }

        let spendLimit = spendLimitUsage(from: payload)
        return isTeamCursorAccount(planName: planName, spendLimit: spendLimit) && !hasLimit
    }

    private func parseUsageSummaryTotalWindow(from summary: [String: Any], resetAt: Date?) -> QuotaWindow? {
        let individual = summary["individualUsage"] as? [String: Any]
        let team = summary["teamUsage"] as? [String: Any]
        let limitType = firstString(in: summary, keys: ["limitType", "limit_type"])?.lowercased()

        if limitType == "team", let pooled = usageSummaryDollarMeter(team?["pooled"]) {
            return QuotaWindow(label: "Total", used: pooled.used, limit: pooled.limit, resetAt: resetAt)
        }

        if let plan = individual?["plan"] as? [String: Any],
           let totalPercentUsed = planUsagePercent(plan, key: "totalPercentUsed") {
            return parsePercentWindow(label: "Total", usedPercent: totalPercentUsed, resetAt: resetAt)
        }

        if let overall = usageSummaryDollarMeter(individual?["overall"]) {
            return QuotaWindow(label: "Total", used: overall.used, limit: overall.limit, resetAt: resetAt)
        }

        if let pooled = usageSummaryDollarMeter(team?["pooled"]) {
            return QuotaWindow(label: "Total", used: pooled.used, limit: pooled.limit, resetAt: resetAt)
        }

        return nil
    }

    private func parseUsageSummaryOnDemandWindow(from summary: [String: Any], resetAt: Date?) -> QuotaWindow? {
        let individual = summary["individualUsage"] as? [String: Any]
        let team = summary["teamUsage"] as? [String: Any]
        if let window = usageSummaryOnDemandWindow(individual?["onDemand"], resetAt: resetAt) {
            return window
        }
        return usageSummaryOnDemandWindow(team?["onDemand"], resetAt: resetAt)
    }

    private func usageSummaryOnDemandWindow(_ value: Any?, resetAt: Date?) -> QuotaWindow? {
        guard let bucket = value as? [String: Any],
              firstBool(in: bucket, keys: ["enabled"]) != false else {
            return nil
        }
        if let meter = usageSummaryDollarMeter(bucket) {
            return QuotaWindow(label: "On-demand", used: meter.used, limit: meter.limit, resetAt: resetAt)
        }
        if let used = directDouble(in: bucket, keys: Self.usedAmountKeys), used > 0 {
            return QuotaWindow(label: "On-demand", used: used, limit: used, resetAt: resetAt)
        }
        return nil
    }

    private func usageSummaryDollarMeter(_ value: Any?) -> (used: Double, limit: Double)? {
        guard let bucket = value as? [String: Any],
              firstBool(in: bucket, keys: ["enabled"]) != false,
              let limit = directDouble(in: bucket, keys: Self.limitAmountKeys),
              limit > 0 else {
            return nil
        }

        let reportedUsed = directDouble(in: bucket, keys: Self.usedAmountKeys)
        let inferredUsed = directDouble(in: bucket, keys: Self.remainingAmountKeys)
            .map { max(limit - $0, 0) }
        let used = (reportedUsed ?? 0) > 0 ? reportedUsed! : (inferredUsed ?? 0)
        return (max(used, 0), limit)
    }

    private func usageSummaryNote(from summary: [String: Any]) -> String? {
        let individual = summary["individualUsage"] as? [String: Any]
        if let plan = individual?["plan"] as? [String: Any],
           let note = includedPlanSpendNote(plan: plan) {
            return note
        }
        if let overall = usageSummaryDollarMeter(individual?["overall"]) {
            return "Included \(formatDollars(overall.used))/\(formatDollars(overall.limit))"
        }
        if let pooled = usageSummaryDollarMeter((summary["teamUsage"] as? [String: Any])?["pooled"]) {
            return "Included \(formatDollars(pooled.used))/\(formatDollars(pooled.limit))"
        }
        return nil
    }
}
