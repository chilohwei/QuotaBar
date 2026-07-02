import Foundation

extension ClaudeCodeProvider {
    func makeQuotaSnapshot(
        status: [String: Any]?,
        credentials: ClaudeCodeCredentials,
        capturedAt: Date? = nil,
        now: Date = Date(),
        rateLimitEvent: ClaudeRateLimitEvent? = nil
    ) -> QuotaSnapshot {
        let primary = makeWindow(status: status, keys: Self.fiveHourLimitKeys, label: "5h", now: now)
        let secondary = makeWindow(status: status, keys: Self.weeklyLimitKeys, label: "7d", now: now)
        let base = QuotaSnapshot(
            source: status == nil ? "Claude Code" : "Claude Code StatusLine",
            accountIdentifier: readableIdentity(from: credentials),
            planName: planName(credentials: credentials, status: status),
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: capturedAt ?? now,
            accountValidUntil: nil,
            subscriptionWillRenew: nil,
            subscriptionStatus: nil,
            isQuotaBlocked: isQuotaBlocked(primary: primary, secondary: secondary),
            availabilityStatus: isQuotaBlocked(primary: primary, secondary: secondary) == true ? .quotaExhausted : nil,
            note: statusNote(
                status: status,
                credentials: credentials,
                hadExpiredWindows: hadExpiredStatusLineWindows(status: status, now: now)
            )
        )
        return applyActiveRateLimit(to: base, rateLimitEvent: rateLimitEvent, now: now)
    }

    /// Overlays an active session/rate limit onto an existing snapshot without rewriting real quota
    /// percentages. A Claude Code 429 means the current session is blocked, but the OAuth/statusLine
    /// windows still carry the real 5h/7d utilization that the panel and menu bar should display.
    func applyActiveRateLimit(
        to snapshot: QuotaSnapshot,
        rateLimitEvent: ClaudeRateLimitEvent?,
        now: Date
    ) -> QuotaSnapshot {
        guard let activeRateLimit = activeRateLimit(
            from: rateLimitEvent,
            fallbackResetAt: snapshot.primary?.resetAt,
            now: now
        ) else {
            return snapshot
        }

        let shouldUseActiveLimitAsPrimary = snapshot.primary == nil
            || snapshot.source == "Claude Code OAuth Cache"
        let primary = shouldUseActiveLimitAsPrimary ? QuotaWindow(
            label: "5h",
            used: 100,
            limit: 100,
            resetAt: activeRateLimit.resetAt
        ) : snapshot.primary!

        return QuotaSnapshot(
            source: snapshot.source,
            accountIdentifier: snapshot.accountIdentifier,
            planName: snapshot.planName,
            primary: primary,
            secondary: snapshot.secondary,
            tertiary: snapshot.tertiary,
            creditsRemaining: snapshot.creditsRemaining,
            creditsTotal: snapshot.creditsTotal,
            updatedAt: snapshot.updatedAt,
            periodEnd: snapshot.periodEnd,
            accountValidUntil: snapshot.accountValidUntil,
            subscriptionWillRenew: snapshot.subscriptionWillRenew,
            subscriptionStatus: snapshot.subscriptionStatus,
            isQuotaBlocked: true,
            availabilityStatus: .sessionRateLimited,
            note: Self.rateLimitReachedNote
        )
    }

    func hadExpiredStatusLineWindows(status: [String: Any]?, now: Date) -> Bool {
        guard let status else { return false }
        let snapshot = QuotaSnapshot(
            source: "Claude Code StatusLine",
            primary: makeWindow(status: status, keys: Self.fiveHourLimitKeys, label: "5h", now: now, rejectExpiredWindows: false),
            secondary: makeWindow(status: status, keys: Self.weeklyLimitKeys, label: "7d", now: now, rejectExpiredWindows: false),
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: now,
            note: nil
        )
        return QuotaFreshness.hasExpiredQuotaWindows(snapshot, now: now)
    }

    func planName(credentials: ClaudeCodeCredentials, status: [String: Any]?) -> String? {
        if let thirdPartyProvider = thirdPartyProviderName(credentials: credentials, status: status) {
            return thirdPartyProvider
        }
        if isFirstPartyClaudeProvider(credentials.apiProvider) || credentials.authMethod == "oauth" {
            return "Claude.ai"
        }
        if let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return displayProviderName(from: provider)
        }
        return nil
    }

    // Note for the non-rate-limited case; an active session limit replaces this with
    // `rateLimitReachedNote` in `applyActiveRateLimit`.
    func statusNote(
        status: [String: Any]?,
        credentials: ClaudeCodeCredentials,
        hadExpiredWindows: Bool = false
    ) -> String? {
        guard status != nil else {
            return QuotaNoteCatalog.claudeAwaitingSession
        }
        if hadExpiredWindows {
            return QuotaNoteCatalog.claudeWindowStale
        }
        if ((status?["rate_limits"] as? [String: Any])?.isEmpty == false) {
            return nil
        }
        let rawProvider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isThirdParty = thirdPartyProviderName(credentials: credentials, status: status) != nil
            || (rawProvider?.isEmpty == false && !isFirstPartyClaudeProvider(rawProvider))
        if credentials.authMethod == "api_key" || isThirdParty {
            return QuotaNoteCatalog.claudeApiKeyNoWindows
        }
        return QuotaNoteCatalog.claudeStatusLineNoWindows
    }

    func isQuotaBlocked(primary: QuotaWindow?, secondary: QuotaWindow?) -> Bool? {
        guard primary != nil || secondary != nil else { return nil }
        return [primary, secondary]
            .compactMap { $0 }
            .contains { $0.usagePercent >= 0.999 }
    }
}
