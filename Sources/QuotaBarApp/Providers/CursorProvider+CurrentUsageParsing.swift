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

    func parseCurrentPeriodUsage(_ payload: Any, credentials: CursorCredentials) throws -> QuotaSnapshot {
        let plan = firstDictionary(
            in: payload,
            keys: Self.includedUsageKeys
        )
        let onDemand = firstDictionary(in: payload, keys: Self.onDemandUsageKeys)
        let planName = normalizedPlanName(
            firstString(in: payload, keys: ["membershipType", "membership_type", "planName", "plan_name"])
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

        let totalPercentUsed = firstDouble(in: payload, keys: ["totalPercentUsed", "total_percent_used"])
        let autoPercentUsed = firstDouble(in: payload, keys: ["autoPercentUsed", "auto_percent_used"])
        let apiPercentUsed = firstDouble(in: payload, keys: ["apiPercentUsed", "api_percent_used"])
        let fallbackWindows = extractCursorUsageWindows(from: payload, defaultResetAt: periodEnd)
        let quotaBlocked = isQuotaBlocked(in: payload)

        let onDemandHasCapacity = onDemandHasPositiveCapacity(onDemand)
        let hasRealCapacity = planHasPositiveCapacity(plan)
            || onDemandHasCapacity
            || !fallbackWindows.isEmpty
        // Free / included accounts meter usage purely as percentages: they carry no
        // spendable dollar limit on the plan and no on-demand budget. When the plan
        // name is absent (Free logins often omit `stripeMembershipType`), fall back
        // to this shape check so such accounts render a single "Total" bar instead of
        // the paid three-bucket Auto / API layout.
        let hasSpendableDollarCapacity = planHasSpendableDollarCapacity(plan) || onDemandHasCapacity
        let isFreePlan = isFreeCursorPlan(planName)
            || (planName == nil && !hasSpendableDollarCapacity)
        let hasPercentUsageSignal = [totalPercentUsed, autoPercentUsed, apiPercentUsed].contains { value in
            guard let value else { return false }
            return value > 0
        }
        // Free / included plans report their allowance only as percentages, so a
        // fully unused account reads as *PercentUsed == 0. That means "100%
        // remaining", not "no quota" — trust the percent windows whenever Cursor
        // is actively metering an included-usage budget on this account.
        let hasIncludedAllowance = hasIncludedUsageAllowance(
            payload: payload,
            plan: plan,
            quotaBlocked: quotaBlocked
        )
        // The Auto / API sub-buckets only carry meaning when backed by real
        // capacity or a non-zero reading (paid plans). A Free account exposes a
        // single included allowance, so it should surface one "Total" bar rather
        // than mirroring the paid three-bucket layout at a flat 100%.
        let canTrustDetailedPercentWindows = !isFreePlan && (hasRealCapacity || hasPercentUsageSignal)
        let canTrustPercentWindows = canTrustDetailedPercentWindows || hasIncludedAllowance

        let primary = parsePlanWindow(plan, resetAt: periodEnd)
            ?? (canTrustPercentWindows ? parsePercentWindow(
                label: "Total",
                usedPercent: totalPercentUsed,
                resetAt: periodEnd
            ) : nil)
            ?? firstCursorWindow(
                in: fallbackWindows,
                preferredLabels: ["Total", "Included", "Requests", "Usage"]
            )
        let auto = isFreePlan ? nil : ((canTrustDetailedPercentWindows ? parsePercentWindow(
            label: "Auto",
            usedPercent: autoPercentUsed,
            resetAt: periodEnd
        ) : nil)
            ?? firstCursorWindow(
                in: fallbackWindows,
                preferredLabels: ["Auto"],
                excluding: [primary],
                allowAnyFallback: false
            ))
        let api = isFreePlan ? nil : ((canTrustDetailedPercentWindows ? parsePercentWindow(
            label: "API",
            usedPercent: apiPercentUsed,
            resetAt: periodEnd
        ) : nil)
            ?? firstCursorWindow(
                in: fallbackWindows,
                preferredLabels: ["API"],
                excluding: [primary, auto],
                allowAnyFallback: false
            ))
        let secondary = isFreePlan ? nil : (auto
            ?? api
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
            ?? firstCursorWindow(
                in: fallbackWindows,
                preferredLabels: ["On-demand", "API", "Requests", "Usage"],
                excluding: [primary, secondary]
            ))
        let note = cursorUsageNote(plan: plan, onDemand: onDemand)

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
                accountIdentifier: cursorAccountEmail(from: credentials),
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
            accountIdentifier: cursorAccountEmail(from: credentials),
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
}
