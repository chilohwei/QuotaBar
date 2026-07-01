import Foundation

extension ClaudeCodeProvider {
    func makeQuotaSnapshot(
        status: [String: Any]?,
        credentials: ClaudeCodeCredentials,
        capturedAt: Date? = nil,
        now: Date = Date(),
        rateLimitEvent: ClaudeRateLimitEvent? = nil
    ) -> QuotaSnapshot {
        let primary = makeWindow(status: status, key: "five_hour", label: "5h", now: now)
        let secondary = makeWindow(status: status, key: "seven_day", label: "7d", now: now)
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
            note: statusNote(
                status: status,
                credentials: credentials,
                hadExpiredWindows: hadExpiredStatusLineWindows(status: status, now: now)
            )
        )
        return applyActiveRateLimit(to: base, rateLimitEvent: rateLimitEvent, now: now)
    }

    /// Overlays an active session/rate limit onto an existing snapshot (e.g. the live OAuth
    /// snapshot, whose rolling-window utilization does not reflect a session limit). When a
    /// limit is active the primary window is forced to 0% remaining and the snapshot is marked
    /// blocked, mirroring what Claude Code shows as "Usage limit reached".
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

        // `activeRateLimit.resetAt` already falls back to the primary window's reset time.
        let primary = QuotaWindow(
            label: snapshot.primary?.label ?? "5h",
            used: 100,
            limit: 100,
            resetAt: activeRateLimit.resetAt
        )

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
            note: Self.rateLimitReachedNote
        )
    }

    func hadExpiredStatusLineWindows(status: [String: Any]?, now: Date) -> Bool {
        guard let status else { return false }
        let snapshot = QuotaSnapshot(
            source: "Claude Code StatusLine",
            primary: makeWindow(status: status, key: "five_hour", label: "5h", now: now, rejectExpiredWindows: false),
            secondary: makeWindow(status: status, key: "seven_day", label: "7d", now: now, rejectExpiredWindows: false),
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
