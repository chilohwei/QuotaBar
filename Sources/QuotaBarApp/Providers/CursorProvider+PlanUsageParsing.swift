import Foundation

extension CursorProvider {
    func spendLimitUsage(from payload: Any) -> [String: Any]? {
        firstDictionary(in: payload, keys: ["spendLimitUsage", "spend_limit_usage"])
    }

    func isTeamCursorAccount(planName: String?, spendLimit: [String: Any]?) -> Bool {
        let normalized = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized == "team" {
            return true
        }
        guard let spendLimit else { return false }
        let limitType = directString(in: spendLimit, keys: ["limitType", "limit_type"])?.lowercased()
        let pooledLimit = directDouble(in: spendLimit, keys: ["pooledLimit", "pooled_limit"]) ?? 0
        return limitType == "team" || pooledLimit > 0
    }

    func planUsagePercent(_ plan: [String: Any]?, key: String) -> Double? {
        guard let plan else { return nil }
        return directDouble(in: plan, keys: [key, key.camelCaseToSnakeCase])
    }

    func parseTeamDollarPlanWindow(_ plan: [String: Any], resetAt: Date?) -> QuotaWindow? {
        guard let limit = directDouble(in: plan, keys: Self.limitAmountKeys), limit > 0 else {
            return nil
        }

        let totalSpend = directDouble(in: plan, keys: ["totalSpend", "total_spend"])
        let includedSpend = directDouble(in: plan, keys: ["includedSpend", "included_spend"])
        let remaining = directDouble(in: plan, keys: Self.remainingAmountKeys)
        let used = totalSpend ?? includedSpend ?? remaining.map { max(limit - $0, 0) }
        guard let used else { return nil }

        return QuotaWindow(
            label: "Total",
            used: min(max(used, 0), limit),
            limit: limit,
            resetAt: resetAt
        )
    }

    func parseIndividualPercentPlanWindow(_ plan: [String: Any], resetAt: Date?) -> QuotaWindow? {
        if let totalPercentUsed = planUsagePercent(plan, key: "totalPercentUsed") {
            return parsePercentWindow(label: "Total", usedPercent: totalPercentUsed, resetAt: resetAt)
        }

        guard let limit = directDouble(in: plan, keys: Self.limitAmountKeys), limit > 0 else {
            return nil
        }

        let totalSpend = directDouble(in: plan, keys: ["totalSpend", "total_spend"])
        let includedSpend = directDouble(in: plan, keys: ["includedSpend", "included_spend"])
        let remaining = directDouble(in: plan, keys: Self.remainingAmountKeys)
        let usedCents = totalSpend ?? includedSpend ?? remaining.map { max(limit - $0, 0) }
        guard let usedCents else { return nil }

        let computedPercent = usedCents / limit * 100
        return parsePercentWindow(label: "Total", usedPercent: computedPercent, resetAt: resetAt)
    }

    func parseSpendLimitOnDemandWindow(_ spendLimit: [String: Any]?, resetAt: Date?) -> QuotaWindow? {
        guard let spendLimit, firstBool(in: spendLimit, keys: ["enabled"]) != false else {
            return nil
        }

        let limit = directDouble(in: spendLimit, keys: ["individualLimit", "individual_limit"])
            ?? directDouble(in: spendLimit, keys: ["pooledLimit", "pooled_limit"])
            ?? directDouble(in: spendLimit, keys: Self.limitAmountKeys)
        guard let limit, limit > 0 else { return nil }

        let remaining = directDouble(in: spendLimit, keys: ["individualRemaining", "individual_remaining"])
            ?? directDouble(in: spendLimit, keys: ["pooledRemaining", "pooled_remaining"])
            ?? directDouble(in: spendLimit, keys: Self.remainingAmountKeys)
        let reportedUsed = [
            directDouble(in: spendLimit, keys: ["individualUsed", "individual_used"]),
            directDouble(in: spendLimit, keys: ["pooledUsed", "pooled_used"]),
            directDouble(in: spendLimit, keys: ["totalSpend", "total_spend"])
        ].compactMap { $0 }.first { $0 > 0 }
        let inferredUsed = remaining.map { max(limit - $0, 0) } ?? 0
        let used = reportedUsed ?? inferredUsed
        guard used > 0 || inferredUsed > 0 else { return nil }

        return QuotaWindow(
            label: "On-demand",
            used: min(max(used, 0), limit),
            limit: limit,
            resetAt: resetAt
        )
    }

    func includedPlanSpendNote(plan: [String: Any]?) -> String? {
        guard let plan,
              let limit = directDouble(in: plan, keys: Self.limitAmountKeys),
              limit > 0 else {
            return nil
        }

        let includedSpend = directDouble(in: plan, keys: ["includedSpend", "included_spend"])
        let totalSpend = directDouble(in: plan, keys: ["totalSpend", "total_spend"])
        let remaining = directDouble(in: plan, keys: Self.remainingAmountKeys)
        let used = includedSpend ?? totalSpend ?? remaining.map { max(limit - $0, 0) }
        guard let used else { return nil }
        return "Included \(formatDollars(used))/\(formatDollars(limit))"
    }

    func cursorSessionToken(from accessToken: String) -> String? {
        guard let subject = jwtStringClaim(accessToken, claim: "sub")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty else {
            return nil
        }
        let parts = subject.split(separator: "|", omittingEmptySubsequences: false)
        let userID = String(parts.count > 1 ? parts[1] : parts[0])
        guard !userID.isEmpty else { return nil }
        return "\(userID)%3A%3A\(accessToken)"
    }
}

private extension String {
    var camelCaseToSnakeCase: String {
        unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty {
                result.append("_")
            }
            result.append(String(scalar).lowercased())
        }
    }
}
