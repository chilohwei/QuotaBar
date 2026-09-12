import Foundation

extension CodexProvider {
    struct TokenIdentity {
        let email: String?
        let plan: String?
        let cycle: String?
        let chatGPTAccountID: String?
        let chatGPTUserID: String?
        let accountValidUntil: Date?
        let subscriptionWillRenew: Bool?
        let subscriptionStatus: String?

        var accountKey: String? {
            guard let chatGPTUserID, let chatGPTAccountID else { return nil }
            return "\(chatGPTUserID)::\(chatGPTAccountID)"
        }
    }

    func extractEmail(fromIDToken token: String?) -> String? {
        extractIdentity(fromIDToken: token).email
    }

    func validateCodexUsageIdentity(
        in payload: Any,
        expectedAccountKey: String?,
        expectedEmail: String?
    ) throws {
        let actual = extractUsageIdentity(from: payload)
        let expectedUserID = expectedAccountKey?
            .split(separator: "::", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpectedEmail = expectedEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let expectedUserID,
           !expectedUserID.isEmpty,
           let actualUserID = actual.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !actualUserID.isEmpty,
           actualUserID != expectedUserID {
            throw ProviderError.network("Codex 返回账号与当前账号不一致，请重新登录该账号")
        }

        if let normalizedExpectedEmail,
           !normalizedExpectedEmail.isEmpty,
           let actualEmail = actual.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !actualEmail.isEmpty,
           actualEmail != normalizedExpectedEmail {
            throw ProviderError.network("Codex 返回账号与当前账号不一致，请重新登录该账号")
        }
    }

    func extractUsageIdentity(from payload: Any) -> CodexUsageIdentity {
        let email = JSONObjectPath.findString(in: payload, keys: ["email", "account_email", "accountEmail"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let userID = JSONObjectPath.findString(in: payload, keys: ["user_id", "userId", "chatgpt_user_id", "chatgptUserId"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = JSONObjectPath.findString(in: payload, keys: ["account_id", "accountId", "chatgpt_account_id", "chatgptAccountId"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexUsageIdentity(
            email: (email?.isEmpty == false) ? email : nil,
            userID: (userID?.isEmpty == false) ? userID : nil,
            accountID: (accountID?.isEmpty == false) ? accountID : nil
        )
    }

    func extractIdentity(fromIDToken token: String?) -> TokenIdentity {
        guard let dict = parseJWT(token) else {
            return TokenIdentity(
                email: nil,
                plan: nil,
                cycle: nil,
                chatGPTAccountID: nil,
                chatGPTUserID: nil,
                accountValidUntil: nil,
                subscriptionWillRenew: nil,
                subscriptionStatus: nil
            )
        }

        let profile = dict["https://api.openai.com/profile"] as? [String: Any]
        let auth = dict["https://api.openai.com/auth"] as? [String: Any]

        let email = ((dict["email"] as? String) ?? (profile?["email"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let plan = extractPlanName(from: dict)
        let cycle = extractBillingCycle(from: dict)
        let chatGPTAccountID = stringValue(in: auth, snakeKey: "chatgpt_account_id", camelKey: "chatgptAccountId")
        let chatGPTUserID = stringValue(in: auth, snakeKey: "chatgpt_user_id", camelKey: "chatgptUserId")
        let subscriptionStatus = extractSubscriptionStatus(from: dict)

        return TokenIdentity(
            email: email?.contains("@") == true ? email : nil,
            plan: plan,
            cycle: cycle,
            chatGPTAccountID: chatGPTAccountID,
            chatGPTUserID: chatGPTUserID,
            accountValidUntil: extractSubscriptionActiveUntil(from: dict),
            subscriptionWillRenew: extractSubscriptionWillRenew(from: dict, subscriptionStatus: subscriptionStatus),
            subscriptionStatus: subscriptionStatus
        )
    }

    func extractSubscriptionActiveUntil(from object: Any) -> Date? {
        findDate(
            in: object,
            keys: [
                "chatgpt_subscription_active_until",
                "chatgptSubscriptionActiveUntil",
                "subscription_active_until",
                "subscriptionActiveUntil",
                "current_period_end",
                "currentPeriodEnd",
                "next_billing_date",
                "nextBillingDate",
                "renewal_date",
                "renewalDate",
                "expires_at",
                "expiresAt",
                "active_until",
                "activeUntil"
            ]
        )
    }

    func extractSubscriptionWillRenew(from object: Any, subscriptionStatus: String?) -> Bool? {
        if let cancelAtPeriodEnd = JSONObjectPath.findBool(
            in: object,
            keys: ["cancel_at_period_end", "cancelAtPeriodEnd"]
        ) {
            return !cancelAtPeriodEnd
        }
        if let willRenew = JSONObjectPath.findBool(
            in: object,
            keys: ["will_renew", "willRenew", "auto_renew", "autoRenew", "renews", "renewing"]
        ) {
            return willRenew
        }
        return inferSubscriptionWillRenew(from: subscriptionStatus)
    }

    func extractSubscriptionStatus(from object: Any) -> String? {
        JSONObjectPath.findString(
            in: object,
            keys: [
                "subscription_status",
                "subscriptionStatus",
                "chatgpt_subscription_status",
                "chatgptSubscriptionStatus",
                "status"
            ]
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    }

    func inferSubscriptionWillRenew(from status: String?) -> Bool? {
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !status.isEmpty else {
            return nil
        }
        switch status {
        case "active", "trialing", "paid":
            return true
        case "canceled", "cancelled", "expired", "incomplete_expired", "unpaid", "past_due":
            return false
        default:
            return nil
        }
    }

    func paidAccountValidUntil(_ planName: String?, _ date: Date?) -> Date? {
        guard let date,
              let planName = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !planName.isEmpty,
              !planName.contains("free"),
              !planName.contains("hobby"),
              !planName.contains("api key"),
              planName != "api" else {
            return nil
        }

        let paidMarkers = ["plus", "pro", "team", "business", "enterprise", "ultra", "max", "unlimited"]
        return paidMarkers.contains { planName.contains($0) } ? date : nil
    }

    func extractPlanName(from object: Any) -> String? {
        JSONObjectPath.findString(
            in: object,
            keys: [
                "chatgpt_plan_type",
                "chatgptPlanType",
                "plan_type",
                "planType",
                "plan_name",
                "planName",
                "plan",
                "account_plan_type",
                "accountPlanType",
                "account_plan",
                "accountPlan",
                "subscription_plan_type",
                "subscriptionPlanType",
                "subscription_plan",
                "subscriptionPlan",
                "billing_plan",
                "billingPlan",
                "membership_type",
                "membershipType",
                "product",
                "product_name",
                "productName",
                "sku",
                "sku_name",
                "skuName",
                "tier",
                "account_tier",
                "accountTier"
            ]
        )
    }

    func extractBillingCycle(from object: Any) -> String? {
        if let cycle = JSONObjectPath.findString(
            in: object,
            keys: [
                "billing_period",
                "billingPeriod",
                "billing_interval",
                "billingInterval",
                "billing_cycle",
                "billingCycle",
                "plan_interval",
                "planInterval",
                "plan_period",
                "planPeriod",
                "subscription_interval",
                "subscriptionInterval",
                "subscription_period",
                "subscriptionPeriod",
                "subscription_billing_cycle",
                "subscriptionBillingCycle",
                "renewal_interval",
                "renewalInterval",
                "renewal_period",
                "renewalPeriod",
                "payment_interval",
                "paymentInterval",
                "recurring_interval",
                "recurringInterval",
                "interval_unit",
                "intervalUnit",
                "interval"
            ]
        ) {
            return cycle
        }

        if JSONObjectPath.findBool(in: object, keys: ["is_annual", "isAnnual", "is_yearly", "isYearly", "annual", "yearly"]) == true {
            return "annual"
        }
        if JSONObjectPath.findBool(in: object, keys: ["is_monthly", "isMonthly", "monthly", "is_month_to_month", "isMonthToMonth"]) == true {
            return "monthly"
        }

        return nil
    }

    func normalizedPlanName(_ raw: String?, cycle rawCycle: String? = nil) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()

        let base: String
        if lower.contains("enterprise") {
            base = "Enterprise"
        } else if lower.contains("team") || lower.contains("business") {
            base = "Team"
        } else if lower.contains("pro") {
            base = "Pro"
        } else if lower.contains("plus") {
            base = "Plus"
        } else if lower.contains("free") {
            base = "Free"
        } else {
            base = raw
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }

        if base.lowercased().contains("free") || base.lowercased() == "api" || base.lowercased().contains("api key") {
            return base
        }

        let cycleSource = [lower, rawCycle?.lowercased()].compactMap { $0 }.joined(separator: " ")
        if cycleSource.contains("annual")
            || cycleSource.contains("annually")
            || cycleSource.contains("yearly")
            || cycleSource.contains("year")
            || cycleSource.contains("p1y")
            || cycleSource.contains(" yr")
            || cycleSource.hasSuffix("yr")
            || cycleSource.contains("12 month")
            || cycleSource.contains("12-month") {
            return "\(base) Annual"
        }
        if cycleSource.contains("monthly")
            || cycleSource.contains("month")
            || cycleSource.contains("p1m")
            || cycleSource.contains(" mo")
            || cycleSource.hasSuffix("mo") {
            return "\(base) Monthly"
        }
        return base
    }

    func parseJWT(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }
}
