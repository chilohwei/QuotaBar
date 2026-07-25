import Foundation

extension CursorProvider {
#if DEBUG
    func parseCurrentPeriodUsageForTesting(
        _ payload: Any,
        email: String? = "fixture@example.com",
        membershipType: String? = nil,
        subscriptionStatus: String? = nil,
        subscriptionPeriodEnd: Date? = nil
    ) throws -> QuotaSnapshot {
        let credentials = CursorCredentials(
            accessToken: "fixture-access-token",
            refreshToken: nil,
            email: email,
            membershipType: membershipType,
            subscriptionStatus: subscriptionStatus,
            subscriptionPeriodEnd: subscriptionPeriodEnd,
            stateDatabasePath: nil,
            source: "fixture"
        )
        return try parseCurrentPeriodUsage(payload, credentials: credentials)
    }
#endif

    func parseCurrentPeriodUsage(_ payload: Any, credentials: CursorCredentials, planNameOverride: String? = nil) throws -> QuotaSnapshot {
        let plan = firstDictionary(
            in: payload,
            keys: Self.includedUsageKeys
        )
        let spendLimit = spendLimitUsage(from: payload)
        let onDemand = firstDictionary(in: payload, keys: Self.onDemandUsageKeys) ?? spendLimit
        let planName = normalizedPlanName(
            planNameOverride
                ?? firstString(in: payload, keys: ["membershipType", "membership_type", "planName", "plan_name"])
                ?? credentials.membershipType
        )
        let periodEnd = firstDate(in: payload, keys: Self.cycleBoundaryDateKeys)
        let accountValidUntil = firstDate(
            in: payload,
            keys: [
                "subscriptionEnd",
                "subscription_end",
                "subscriptionExpiresAt",
                "subscription_expires_at",
                "activeUntil",
                "active_until",
                "expiresAt",
                "expires_at",
                "nextBillingDate",
                "next_billing_date"
            ]
        ) ?? credentials.subscriptionPeriodEnd
        let subscriptionStatus = firstString(in: payload, keys: ["subscriptionStatus", "subscription_status", "status", "stripeSubscriptionStatus"])
            ?? credentials.subscriptionStatus
        let accountIdentifier = cursorAccountIdentifier(from: payload, credentials: credentials)

        let totalPercentUsed = plan.flatMap { planUsagePercent($0, key: "totalPercentUsed") }
        let autoPercentUsed = plan.flatMap { planUsagePercent($0, key: "autoPercentUsed") }
        let apiPercentUsed = plan.flatMap { planUsagePercent($0, key: "apiPercentUsed") }
        let fallbackWindows = extractCursorUsageWindows(from: payload, defaultResetAt: periodEnd)
        let quotaBlocked = isQuotaBlocked(in: payload)
        let isTeamAccount = isTeamCursorAccount(planName: planName, spendLimit: spendLimit)

        let onDemandHasCapacity = onDemandHasPositiveCapacity(onDemand)
        let hasRealCapacity = planHasPositiveCapacity(plan)
            || onDemandHasCapacity
            || !fallbackWindows.isEmpty
        let hasSpendableDollarCapacity = planHasSpendableDollarCapacity(plan) || onDemandHasCapacity
        let isFreePlan = isFreeCursorPlan(planName)
            || (planName == nil && !hasSpendableDollarCapacity)
        let hasPercentUsageSignal = [totalPercentUsed, autoPercentUsed, apiPercentUsed].contains { value in
            guard let value else { return false }
            return value > 0
        }
        let hasIncludedAllowance = hasIncludedUsageAllowance(
            payload: payload,
            plan: plan,
            quotaBlocked: quotaBlocked
        )
        let canTrustDetailedPercentWindows = !isFreePlan && (hasRealCapacity || hasPercentUsageSignal)
        let canTrustPercentWindows = canTrustDetailedPercentWindows || hasIncludedAllowance

        let primary: QuotaWindow? = {
            if isFreePlan {
                return (canTrustPercentWindows ? parsePercentWindow(
                    label: "Total",
                    usedPercent: totalPercentUsed,
                    resetAt: periodEnd
                ) : nil)
                    ?? firstCursorWindow(
                        in: fallbackWindows,
                        preferredLabels: ["Total", "Included", "Requests", "Usage"]
                    )
            }

            if let plan {
                if isTeamAccount, let teamWindow = parseTeamDollarPlanWindow(plan, resetAt: periodEnd) {
                    return teamWindow
                }
                if let individualWindow = parseIndividualPercentPlanWindow(plan, resetAt: periodEnd) {
                    return individualWindow
                }
            }

            return (canTrustPercentWindows ? parsePercentWindow(
                label: "Total",
                usedPercent: totalPercentUsed,
                resetAt: periodEnd
            ) : nil)
                ?? firstCursorWindow(
                    in: fallbackWindows,
                    preferredLabels: ["Total", "Included", "Requests", "Usage"]
                )
        }()

        let auto = isFreePlan ? nil : (parsePercentWindow(
            label: "Auto",
            usedPercent: autoPercentUsed,
            resetAt: periodEnd
        ) ?? firstCursorWindow(
            in: fallbackWindows,
            preferredLabels: ["Auto"],
            excluding: [primary],
            allowAnyFallback: false
        ))
        let api = isFreePlan ? nil : (parsePercentWindow(
            label: "API",
            usedPercent: apiPercentUsed,
            resetAt: periodEnd
        ) ?? firstCursorWindow(
            in: fallbackWindows,
            preferredLabels: ["API"],
            excluding: [primary, auto],
            allowAnyFallback: false
        ))
        let secondary = isFreePlan ? nil : (auto
            ?? api
            ?? parseSpendLimitOnDemandWindow(spendLimit, resetAt: periodEnd)
            ?? firstCursorWindow(
                in: fallbackWindows,
                preferredLabels: ["Requests", "Usage", "On-demand"],
                excluding: [primary]
            ))
        let tertiaryFromAPI: QuotaWindow? = {
            guard !isFreePlan, let api else { return nil }
            let earlierWindows = [primary, secondary].compactMap { $0 }
            return earlierWindows.contains(where: { sameCursorWindow($0, api) }) ? nil : api
        }()
        let tertiary = isFreePlan ? nil : (tertiaryFromAPI
            ?? parseSpendLimitOnDemandWindow(spendLimit, resetAt: periodEnd)
            ?? firstCursorWindow(
                in: fallbackWindows,
                preferredLabels: ["On-demand", "API", "Requests", "Usage"],
                excluding: [primary, secondary]
            ))
        let note = cursorUsageNote(plan: plan, onDemand: onDemand, spendLimit: spendLimit)

        // Some free / zero-quota payloads include *PercentUsed=0 placeholders.
        // Those should not be rendered as "100% remaining".
        if primary == nil, secondary == nil, tertiary == nil,
           !hasRealCapacity,
           !hasPercentUsageSignal,
           !hasIncludedAllowance,
           usagePayloadHasOnlyZeroOrNoQuotaSignals(
               plan: plan,
               onDemand: onDemand,
               totalPercentUsed: totalPercentUsed,
               autoPercentUsed: autoPercentUsed,
               apiPercentUsed: apiPercentUsed
           ) || quotaBlocked == true {
            return QuotaSnapshot(
                source: "Cursor",
                accountIdentifier: accountIdentifier,
                planName: planName,
                primary: nil,
                secondary: nil,
                tertiary: nil,
                creditsRemaining: nil,
                creditsTotal: nil,
                updatedAt: .init(),
                periodEnd: periodEnd,
                accountValidUntil: accountValidUntil,
                subscriptionWillRenew: inferSubscriptionWillRenew(from: subscriptionStatus),
                subscriptionStatus: normalizedSubscriptionStatus(subscriptionStatus),
                isQuotaBlocked: quotaBlocked,
                availabilityStatus: quotaBlocked == true ? .quotaExhausted : nil,
                note: note
            )
        }

        guard primary != nil || secondary != nil || tertiary != nil else {
            throw ProviderError.network("Cursor 返回成功，但未识别到用量字段")
        }

        return QuotaSnapshot(
            source: "Cursor",
            accountIdentifier: accountIdentifier,
            planName: planName,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: .init(),
            periodEnd: periodEnd,
            accountValidUntil: accountValidUntil,
            subscriptionWillRenew: inferSubscriptionWillRenew(from: subscriptionStatus),
            subscriptionStatus: normalizedSubscriptionStatus(subscriptionStatus),
            isQuotaBlocked: quotaBlocked,
            availabilityStatus: quotaBlocked == true ? .quotaExhausted : nil,
            note: note
        )
    }

    func cursorAccountIdentifier(from payload: Any, credentials: CursorCredentials) -> String? {
        firstString(
            in: payload,
            keys: [
                "email",
                "userEmail",
                "user_email",
                "accountEmail",
                "account_email",
                "primaryEmail",
                "primary_email"
            ]
        ).flatMap { emailAddress(in: $0) } ?? cursorAccountEmail(from: credentials)
    }
}
