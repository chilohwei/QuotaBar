import Foundation

extension CodexProvider {
#if DEBUG
    func parseRateLimitPayloadForTesting(
        _ payload: Any,
        accountIdentifier: String? = "fixture@example.com",
        planName: String? = nil,
        accountValidUntil: Date? = nil,
        subscriptionWillRenew: Bool? = nil,
        subscriptionStatus: String? = nil
    ) -> QuotaSnapshot? {
        parseCodexRateLimitPayload(
            payload,
            fallbackAccountIdentifier: accountIdentifier,
            fallbackPlanName: planName,
            fallbackAccountValidUntil: accountValidUntil,
            fallbackSubscriptionWillRenew: subscriptionWillRenew,
            fallbackSubscriptionStatus: subscriptionStatus
        )
    }
#endif

    func parseCodexRateLimitPayload(
        _ payload: Any,
        fallbackAccountIdentifier: String?,
        fallbackPlanName: String?,
        fallbackAccountValidUntil: Date?,
        fallbackSubscriptionWillRenew: Bool?,
        fallbackSubscriptionStatus: String?
    ) -> QuotaSnapshot? {
        guard let dict = payload as? [String: Any] else { return nil }
        guard let rateLimit = (dict["rate_limit"] as? [String: Any])
            ?? (dict["rateLimit"] as? [String: Any]) else { return nil }

        let primary = parseCodexWindow(
            (rateLimit["primary_window"] as? [String: Any])
                ?? (rateLimit["primaryWindow"] as? [String: Any])
        )
        let secondary = parseCodexWindow(
            (rateLimit["secondary_window"] as? [String: Any])
                ?? (rateLimit["secondaryWindow"] as? [String: Any])
        )
        let extraWindows = parseCodexExtraWindows(from: dict)
        let credits = dict["credits"] as? [String: Any]
        let creditsRemaining = credits.flatMap {
            firstDouble(in: $0, keys: ["balance", "remaining", "available", "total_available", "totalAvailable"])
        }
        let creditsTotal = credits.flatMap { creditDict -> Double? in
            if let total = firstDouble(in: creditDict, keys: ["total", "limit", "granted", "total_granted", "totalGranted"]) {
                return total
            }
            if let remaining = creditsRemaining,
               let used = firstDouble(in: creditDict, keys: ["used", "spent", "total_used", "totalUsed"]) {
                return remaining + used
            }
            return nil
        }
        let planName = normalizedPlanName(
            extractPlanName(from: dict) ?? fallbackPlanName,
            cycle: extractBillingCycle(from: dict)
        )
        let allowed = (rateLimit["allowed"] as? Bool)
        let limitReached = (rateLimit["limit_reached"] as? Bool)
            ?? (rateLimit["limitReached"] as? Bool)
        let isBlocked = (limitReached == true) || (allowed == false)

        let snapshot = QuotaSnapshot(
            source: "Codex OAuth",
            accountIdentifier: fallbackAccountIdentifier,
            planName: planName,
            primary: primary,
            secondary: secondary,
            extraWindows: extraWindows,
            creditsRemaining: creditsRemaining,
            creditsTotal: creditsTotal,
            updatedAt: .init(),
            periodEnd: nil,
            accountValidUntil: paidAccountValidUntil(planName, fallbackAccountValidUntil),
            subscriptionWillRenew: fallbackSubscriptionWillRenew,
            subscriptionStatus: fallbackSubscriptionStatus,
            isQuotaBlocked: isBlocked,
            availabilityStatus: isBlocked ? .quotaExhausted : nil,
            note: (primary == nil && secondary == nil && extraWindows.isEmpty && creditsRemaining == nil)
                ? QuotaNoteCatalog.codexEmptyQuotaFields
                : nil
        )
        return snapshot
    }

    func parseCodexWindow(
        _ dict: [String: Any]?,
        labelPrefix: String? = nil,
        fallbackWindowSeconds: Int = 0
    ) -> QuotaWindow? {
        guard let dict else { return nil }

        guard var usedPercent = firstDouble(in: dict, keys: ["used_percent", "usedPercent"]) else { return nil }
        if usedPercent > 0, usedPercent < 1 {
            usedPercent *= 100
        }
        usedPercent = min(max(usedPercent, 0), 100)

        let windowSeconds = firstInt(in: dict, keys: ["limit_window_seconds", "limitWindowSeconds"])
            ?? firstInt(in: dict, keys: ["window_minutes", "windowMinutes"]).map { $0 * 60 }
            ?? fallbackWindowSeconds
        let resetAt = parseFlexibleDate(firstValue(in: dict, keys: ["reset_at", "resetAt", "resets_at", "resetsAt"]))
            ?? firstDouble(in: dict, keys: ["reset_after_seconds", "resetAfterSeconds"]).map {
                Date().addingTimeInterval($0)
            }
        let label = prefixedCodexWindowLabel(labelForWindow(seconds: windowSeconds), prefix: labelPrefix)

        return QuotaWindow(
            label: label,
            used: usedPercent,
            limit: 100,
            resetAt: resetAt
        )
    }

    func parseCodexExtraWindows(from dict: [String: Any]) -> [QuotaWindow] {
        uniqueCodexWindows(
            parseAdditionalCodexRateLimitWindows(from: dict)
                + parseCodexCodeReviewWindows(from: dict)
        )
    }

    func parseAdditionalCodexRateLimitWindows(from dict: [String: Any]) -> [QuotaWindow] {
        guard let entries = dict["additional_rate_limits"] as? [[String: Any]] else {
            return []
        }
        return entries.flatMap { entry -> [QuotaWindow] in
            guard let rateLimit = (entry["rate_limit"] as? [String: Any])
                ?? (entry["rateLimit"] as? [String: Any]) else {
                return [QuotaWindow]()
            }
            let displayName = codexAdditionalLimitDisplayName(from: entry)
            if displayName == "Spark" {
                return [QuotaWindow]()
            }
            return parseCodexNamedRateLimitWindows(
                rateLimit,
                prefix: displayName
            )
        }
    }

    func parseCodexCodeReviewWindows(from dict: [String: Any]) -> [QuotaWindow] {
        guard let rateLimit = (dict["code_review_rate_limit"] as? [String: Any])
            ?? (dict["codeReviewRateLimit"] as? [String: Any]) else {
            return []
        }
        return parseCodexNamedRateLimitWindows(rateLimit, prefix: "Code Review")
    }

    func parseCodexNamedRateLimitWindows(_ rateLimit: [String: Any], prefix: String) -> [QuotaWindow] {
        [
            parseCodexWindow(
                (rateLimit["primary_window"] as? [String: Any])
                    ?? (rateLimit["primaryWindow"] as? [String: Any]),
                labelPrefix: prefix,
                fallbackWindowSeconds: 18_000
            ),
            parseCodexWindow(
                (rateLimit["secondary_window"] as? [String: Any])
                    ?? (rateLimit["secondaryWindow"] as? [String: Any]),
                labelPrefix: prefix,
                fallbackWindowSeconds: 604_800
            )
        ].compactMap { $0 }
    }

    func codexAdditionalLimitDisplayName(from entry: [String: Any]) -> String {
        let rawName = firstString(in: entry, keys: ["limit_name", "limitName", "name", "metered_feature", "meteredFeature"])
            ?? "Extra"
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("spark") {
            return "Spark"
        }
        if trimmed.localizedCaseInsensitiveContains("bengalfox") {
            return "Spark"
        }
        return trimmed.isEmpty ? "Extra" : trimmed
    }

    func prefixedCodexWindowLabel(_ label: String, prefix: String?) -> String {
        guard let prefix = prefix?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prefix.isEmpty else {
            return label
        }
        return "\(prefix) \(label)"
    }

    func uniqueCodexWindows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        var seen = Set<String>()
        return windows.filter { window in
            let reset = window.resetAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "none"
            return seen.insert("\(window.label)-\(window.used)-\(window.limit)-\(reset)").inserted
        }
    }

    func firstValue(in dict: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dict[key] {
                return value
            }
        }
        return nil
    }

    func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let text = value as? String {
                return text
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    func firstBool(in dict: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let bool = value as? Bool {
                return bool
            }
            if let number = value as? NSNumber {
                return number.boolValue
            }
            if let text = value as? String {
                switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "1":
                    return true
                case "false", "no", "0":
                    return false
                default:
                    continue
                }
            }
        }
        return nil
    }

    func firstDouble(in dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let number = value as? NSNumber { return number.doubleValue }
            if let number = value as? Double { return number }
            if let number = value as? Int { return Double(number) }
            if let text = value as? String, let number = parseLooseDouble(text) { return number }
        }
        return nil
    }

    func parseLooseDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed) {
            return number
        }

        let cleaned = trimmed
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    func firstInt(in dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let number = value as? NSNumber { return number.intValue }
            if let number = value as? Int { return number }
            if let number = value as? Double { return Int(number) }
            if let text = value as? String, let number = Int(text) { return number }
        }
        return nil
    }

    func labelForWindow(seconds: Int) -> String {
        switch seconds {
        case 18_000:
            return "5h"
        case 604_800:
            return "Weekly"
        case 2_592_000:
            return "Monthly"
        default:
            return "Usage"
        }
    }
}
