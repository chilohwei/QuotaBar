import Foundation

extension CursorProvider {
    func planHasPositiveCapacity(_ plan: [String: Any]?) -> Bool {
        guard let plan else { return false }
        let limit = firstDouble(in: plan, keys: Self.limitAmountKeys) ?? 0
        let remaining = firstDouble(in: plan, keys: Self.remainingAmountKeys) ?? 0
        let used = firstDouble(in: plan, keys: Self.usedAmountKeys) ?? 0
        return limit > 0 || remaining > 0 || used > 0
    }

    // A spendable dollar budget requires a positive *limit* or *remaining*. A bare
    // `used` / `totalSpend` figure does not: Free accounts report their consumed
    // bonus allowance as `totalSpend` with no limit, which must not be mistaken for
    // paid capacity. Used to tell an included-usage (Free) account — metered purely
    // as percentages — apart from a paid plan that has real dollar headroom.
    func planHasSpendableDollarCapacity(_ plan: [String: Any]?) -> Bool {
        guard let plan else { return false }
        let limit = firstDouble(in: plan, keys: Self.limitAmountKeys) ?? 0
        let remaining = firstDouble(in: plan, keys: Self.remainingAmountKeys) ?? 0
        return limit > 0 || remaining > 0
    }

    func planExplicitlyHasNoCapacity(_ plan: [String: Any]?) -> Bool {
        guard let plan else { return false }
        let limit = firstDouble(in: plan, keys: Self.limitAmountKeys)
        let remaining = firstDouble(in: plan, keys: Self.remainingAmountKeys)
        let used = firstDouble(in: plan, keys: Self.usedAmountKeys)
        guard limit != nil || remaining != nil || used != nil else { return false }
        return (limit ?? 0) <= 0 && (remaining ?? 0) <= 0 && (used ?? 0) <= 0
    }

    func usagePayloadHasOnlyZeroOrNoQuotaSignals(
        plan: [String: Any]?,
        onDemand: [String: Any]?,
        totalPercentUsed: Double?,
        autoPercentUsed: Double?,
        apiPercentUsed: Double?
    ) -> Bool {
        let hasZeroPercentTriplet =
            totalPercentUsed != nil && autoPercentUsed != nil && apiPercentUsed != nil
            && (totalPercentUsed ?? 1) == 0
            && (autoPercentUsed ?? 1) == 0
            && (apiPercentUsed ?? 1) == 0

        let hasZeroOnDemandLimits: Bool = {
            guard let onDemand else { return false }
            let pooledLimit = firstDouble(in: onDemand, keys: ["pooledLimit", "pooled_limit"]) ?? 0
            let individualLimit = firstDouble(in: onDemand, keys: ["individualLimit", "individual_limit"]) ?? 0
            let overallLimit = firstDouble(in: onDemand, keys: ["overallLimit", "overall_limit", "limit"]) ?? 0
            let pooledRemaining = firstDouble(in: onDemand, keys: ["pooledRemaining", "pooled_remaining"]) ?? 0
            let overallRemaining = firstDouble(in: onDemand, keys: ["overallRemaining", "overall_remaining", "remaining"]) ?? 0
            return pooledLimit <= 0
                && individualLimit <= 0
                && overallLimit <= 0
                && pooledRemaining <= 0
                && overallRemaining <= 0
        }()

        return planExplicitlyHasNoCapacity(plan) || hasZeroOnDemandLimits || hasZeroPercentTriplet
    }

    // Detects an active included-usage budget on plans (notably Free) that express
    // their allowance purely as percentages. Without this, a brand-new / unused
    // account — every *PercentUsed == 0 — is indistinguishable from a quota-less
    // placeholder and gets hidden, even though 0% used means full quota remaining.
    func hasIncludedUsageAllowance(payload: Any, plan: [String: Any]?, quotaBlocked: Bool?) -> Bool {
        guard quotaBlocked != true, let plan else { return false }

        let percentKeys: Set<String> = [
            "totalPercentUsed", "total_percent_used",
            "autoPercentUsed", "auto_percent_used",
            "apiPercentUsed", "api_percent_used"
        ]
        // The included object must actually carry percent metering for this to apply.
        guard directDouble(in: plan, keys: percentKeys) != nil else { return false }

        // Cursor only reports a positive display threshold / an "included usage"
        // message when the account has an included budget to spend.
        if (firstDouble(in: payload, keys: ["displayThreshold", "display_threshold"]) ?? 0) > 0 {
            return true
        }
        if let message = firstString(in: payload, keys: [
            "displayMessage", "display_message",
            "autoModelSelectedDisplayMessage", "auto_model_selected_display_message",
            "namedModelSelectedDisplayMessage", "named_model_selected_display_message"
        ]), message.lowercased().contains("included") {
            return true
        }
        return false
    }

    func onDemandHasPositiveCapacity(_ onDemand: [String: Any]?) -> Bool {
        guard let onDemand else { return false }
        let limit = firstDouble(in: onDemand, keys: Self.limitAmountKeys.union([
            "pooledLimit",
            "pooled_limit",
            "individualLimit",
            "individual_limit",
            "overallLimit",
            "overall_limit"
        ])) ?? 0
        let remaining = firstDouble(in: onDemand, keys: Self.remainingAmountKeys.union([
            "pooledRemaining",
            "pooled_remaining",
            "individualRemaining",
            "individual_remaining",
            "overallRemaining",
            "overall_remaining"
        ])) ?? 0
        let used = firstDouble(in: onDemand, keys: Self.usedAmountKeys.union([
            "pooledUsed",
            "pooled_used",
            "individualUsed",
            "individual_used",
            "overallUsed",
            "overall_used"
        ])) ?? 0
        return limit > 0 || remaining > 0 || used > 0
    }
}
