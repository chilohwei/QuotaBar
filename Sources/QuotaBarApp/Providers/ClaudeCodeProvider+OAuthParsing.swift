import Foundation

extension ClaudeCodeProvider {
    func makeOAuthUsageSnapshot(
        payload: [String: Any],
        credentials: ClaudeCodeCredentials
    ) -> QuotaSnapshot {
        let legacyPrimary = parseOAuthUsageWindow(
            usageWindowDictionary(in: payload, keys: Self.fiveHourLimitKeys),
            label: "5h"
        )
        let legacySecondary = parseOAuthUsageWindow(
            usageWindowDictionary(in: payload, keys: Self.weeklyLimitKeys),
            label: "7d"
        )

        // Newer `/usage` payloads null out `seven_day` and move the weekly windows into a
        // `limits` array (entries carry `group`, `percent`, `resets_at`, and for model-scoped
        // weekly limits a `scope.model.display_name` like "Fable").
        let limitWindows = parseOAuthLimitsArray(payload["limits"])
        let primary = legacyPrimary ?? limitWindows.session
        var weekly = limitWindows.weekly
        if let legacySecondary {
            weekly.removeAll { $0.label == legacySecondary.label }
            weekly.insert(legacySecondary, at: 0)
        }
        // Legacy OAuth responses expose model windows outside the limits array.
        for (key, name) in [("seven_day_sonnet", "Sonnet"), ("seven_day_opus", "Opus")] {
            if let window = parseOAuthUsageWindow(payload[key] as? [String: Any], label: "7d·\(name)"),
               !weekly.contains(where: { $0.label == window.label }) {
                weekly.append(window)
            }
        }
        let secondary = weekly.first { $0.label == "7d" }
        let modelWindows = weekly.filter { $0.label != "7d" }
        let tertiary = modelWindows.first
        let routines = parseOAuthUsageWindow(
            (payload["seven_day_routines"] as? [String: Any]) ?? (payload["seven_day_cowork"] as? [String: Any]),
            label: "Routines 7d"
        )
        let spending = parseExtraUsageSpend(payload["extra_usage"] as? [String: Any])

        return QuotaSnapshot(
            source: "Claude Code OAuth",
            accountIdentifier: readableIdentity(from: credentials),
            planName: planName(credentials: credentials, status: nil),
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraWindows: Array(modelWindows.dropFirst()) + [routines].compactMap { $0 },
            creditsRemaining: nil,
            creditsTotal: nil,
            spending: spending.map { [$0] } ?? [],
            updatedAt: Date(),
            accountValidUntil: nil,
            subscriptionWillRenew: nil,
            subscriptionStatus: nil,
            isQuotaBlocked: isQuotaBlocked(primary: primary, secondary: secondary),
            availabilityStatus: isQuotaBlocked(primary: primary, secondary: secondary) == true ? .quotaExhausted : nil,
            note: nil
        )
    }

    func parseExtraUsageSpend(_ payload: [String: Any]?) -> QuotaSpend? {
        guard let payload, payload["is_enabled"] as? Bool == true,
              let used = number(payload["used_credits"]), used.isFinite, used >= 0 else { return nil }
        let limit = number(payload["monthly_limit"]).flatMap { $0.isFinite && $0 >= 0 ? $0 / 100 : nil }
        let currency = (payload["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuotaSpend(label: "Extra usage", used: used / 100, limit: limit, currency: currency?.isEmpty == false ? currency!.uppercased() : "USD",
                          resetAt: parseFlexibleDate(payload["resets_at"]))
    }

    struct OAuthLimitWindows {
        var session: QuotaWindow?
        var weekly: [QuotaWindow] = []
    }

    /// Parses the `limits` array of newer `/usage` payloads. Entries look like
    /// `{kind: "session"|"weekly"|"weekly_scoped", group: "session"|"weekly", percent: 54,
    ///   resets_at: "...", scope: {model: {display_name: "Fable"}}}`.
    /// `is_active` is deliberately ignored: it marks the currently binding window, not
    /// whether the limit exists — the CLI's own usage panel shows inactive windows too.
    func parseOAuthLimitsArray(_ value: Any?) -> OAuthLimitWindows {
        var result = OAuthLimitWindows()
        guard let entries = value as? [[String: Any]] else { return result }
        for entry in entries {
            guard let percent = number(entry["percent"]) ?? number(entry["utilization"]), percent.isFinite else {
                continue
            }
            let group = ((entry["group"] as? String) ?? (entry["kind"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let resetAt = parseFlexibleDate(firstValue(
                in: entry,
                keys: ["resets_at", "reset_at", "resetAt", "resetsAt"]
            ))
            func window(_ label: String) -> QuotaWindow {
                QuotaWindow(label: label, used: min(max(percent, 0), 100), limit: 100, resetAt: resetAt)
            }
            switch group {
            case "session":
                if result.session == nil {
                    result.session = window("5h")
                }
            case "weekly", "weekly_scoped":
                let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
                let modelName = (model?["display_name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let generic = ["all models", "all", "default"].contains(modelName?.lowercased() ?? "")
                let label = (modelName?.isEmpty == false && !generic) ? "7d·\(modelName!)" : "7d"
                result.weekly.append(window(label))
            default:
                continue
            }
        }
        // The all-models weekly window ahead of model-scoped ones.
        result.weekly.sort { lhs, rhs in
            (lhs.label == "7d" ? 0 : 1) < (rhs.label == "7d" ? 0 : 1)
        }
        return result
    }
}
