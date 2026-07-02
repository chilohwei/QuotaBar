import Foundation

extension ClaudeCodeProvider {
    func importCurrentCredentials() async throws -> String {
        let credentials = try await readClaudeCodeCredentials()
        guard credentials.loggedIn else {
            throw ProviderError.unsupported(claudeLoginRequiredMessage)
        }
        return try encodeCredentials(credentials)
    }

    func authenticateViaBrowser() async throws -> String {
        do {
            let previous = try? await readClaudeCodeCredentials()
            try await runClaudeAuthLogin(timeout: 300)
            let credentials = try await readClaudeCodeCredentials()
            guard credentials.loggedIn else {
                throw ProviderError.unsupported(claudeLoginRequiredMessage)
            }
            if shouldClearStatusLineSnapshot(previous: previous, next: credentials) {
                try? fileService.removeItemIfExists(at: AppPaths.claudeCodeStatusFile.path)
            }
            return try encodeCredentials(credentials)
        } catch {
            openClaudeCodePage()
            if case ProviderError.unsupported = error {
                throw error
            }
            throw ProviderError.unsupported(claudeLoginRequiredMessage)
        }
    }

    func prepareAccount(_ account: Account, secret: String) async throws -> Account {
        var updated = account
        updated.settings.identityKey = accountIdentity(from: secret) ?? account.settings.identityKey
        return updated
    }

    func activate(account: Account, secret: String) async throws {
        let stored = try parseCredentials(secret)
        let previous = try? await readClaudeCodeCredentials()
        var replacedCredentials = false
        if hasRestorableClaudeArtifacts(stored) {
            try restoreClaudeArtifacts(from: stored)
            replacedCredentials = true
        }
        if let keychainCredentials = stored.keychainCredentials?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainCredentials.isEmpty {
            try writeClaudeCodeKeychainCredentials(keychainCredentials)
            try writeClaudeUserID(stored.userID)
            replacedCredentials = true
        }
        let latest = try await readClaudeCodeCredentials()
        guard latest.loggedIn,
              claudeCredentialsRepresentSameAccount(latest, stored) else {
            throw ProviderError.unsupported("Claude Code 切换后读取到的账号不一致；请在 Claude Code 中切到该账号后重新添加。")
        }
        if replacedCredentials, shouldClearStatusLineSnapshot(previous: previous, next: stored) {
            try? fileService.removeItemIfExists(at: AppPaths.claudeCodeStatusFile.path)
        }
        try installQuotaBarStatusLine()
    }

    func fetchQuota(secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: Account(tool: .claudeCode, name: "Claude Code"), secret: secret)
    }

    func fetchQuota(account: Account, secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: account, secret: secret, intent: .background)
    }

    func fetchQuota(account: Account, secret: String, intent: RefreshIntent) async throws -> QuotaSnapshot {
        let storedCredentials = try parseCredentials(secret)
        let credentials: ClaudeCodeCredentials
        if let latest = try? await readClaudeCodeCredentials(),
           claudeCredentialsRepresentSameAccount(latest, storedCredentials) {
            credentials = mergeCredentials(preferred: latest, fallback: storedCredentials)
        } else {
            credentials = storedCredentials
        }

        let now = Date()
        let statusLineLoad = try? loadStatusLineSnapshot()
        let rateLimitEvent = loadActiveRateLimitEvent(status: statusLineLoad?.status, now: now)
        let cachedOAuthSnapshot = loadCachedOAuthUsage(credentials: credentials)
            .flatMap(historicalLiveFallback)
        let statusLineStatus = shouldUseStatusLineSnapshot(statusLineLoad?.status, settingsJSON: credentials.claudeSettingsJSON)
            ? statusLineLoad?.status
            : nil
        let statusLineSnapshot = makeQuotaSnapshot(
            status: statusLineStatus,
            credentials: credentials,
            capturedAt: statusLineLoad?.capturedAt,
            now: now,
            rateLimitEvent: rateLimitEvent
        )
        let hasUsableStatusLineSnapshot = shouldUseStatusLineSnapshotAsPrimary(statusLineSnapshot)
        let canFillFromHistoricalOAuthCache = statusLineSnapshot.effectiveAvailabilityStatus == .sessionRateLimited
            || !statusLineSnapshot.orderedMetrics.isEmpty
        let statusLineOrCachedSnapshot = canFillFromHistoricalOAuthCache ? (cachedOAuthSnapshot.map {
            mergeClaudeSnapshot(statusLineSnapshot, fillingMissingMetricsFrom: $0)
        } ?? statusLineSnapshot) : statusLineSnapshot

        // For first-party Claude.ai OAuth accounts, the official usage endpoint is the source of
        // truth for quota percentages. statusLine is fast and useful, but Claude Code can freeze its
        // `rate_limits` between API calls, so use it as a fallback when live usage is unavailable.
        // The live OAuth `utilization` numbers track the 5h/7d rolling windows, which are
        // distinct from the session limit Claude Code reports via a 429 "Usage limit reached".
        if let liveSnapshot = try await fetchOAuthUsageSnapshot(credentials: credentials, intent: intent) {
            let preferredSnapshot = preferredClaudeSnapshot(
                liveSnapshot: liveSnapshot,
                statusLineSnapshot: statusLineSnapshot,
                hasUsableStatusLineSnapshot: hasUsableStatusLineSnapshot
            )
            return applyActiveRateLimit(to: preferredSnapshot, rateLimitEvent: rateLimitEvent, now: now)
        }

        // The OAuth fallback path being down *because Anthropic is rate-limiting us* is a distinct,
        // actionable state. Override the generic note (but never the real "usage limit reached" one)
        // so the panel explains it will self-recover and how to force a fix if it lingers.
        if statusLineSnapshot.isQuotaBlocked != true, isAuthRateLimited(credentials, now: now) {
            return statusLineOrCachedSnapshot.replacing(
                note: Self.usageRateLimitedNote,
                availabilityStatus: .authRateLimited
            )
        }
        if hasUsableStatusLineSnapshot {
            return applyActiveRateLimit(to: statusLineOrCachedSnapshot, rateLimitEvent: rateLimitEvent, now: now)
        }
        return statusLineOrCachedSnapshot
    }

    func preferredClaudeSnapshot(
        liveSnapshot: QuotaSnapshot,
        statusLineSnapshot: QuotaSnapshot,
        hasUsableStatusLineSnapshot: Bool
    ) -> QuotaSnapshot {
        guard hasUsableStatusLineSnapshot else {
            return liveSnapshot
        }
        if liveSnapshot.source == "Claude Code OAuth Cache",
           statusLineSnapshot.updatedAt > liveSnapshot.updatedAt {
            return statusLineSnapshot
        }
        return mergeClaudeSnapshot(liveSnapshot, fillingMissingMetricsFrom: statusLineSnapshot)
    }

    func mergeClaudeSnapshot(
        _ preferred: QuotaSnapshot,
        fillingMissingMetricsFrom fallback: QuotaSnapshot
    ) -> QuotaSnapshot {
        let primary = preferred.primary ?? fallback.primary
        let secondary = preferred.secondary ?? fallback.secondary
        let tertiary = preferred.tertiary ?? fallback.tertiary

        guard primary != preferred.primary
            || secondary != preferred.secondary
            || tertiary != preferred.tertiary else {
            return preferred
        }

        let isBlocked = preferred.isQuotaBlocked == true
            || fallback.isQuotaBlocked == true
            || isQuotaBlocked(primary: primary, secondary: secondary) == true
        let availabilityStatus = preferred.availabilityStatus
            ?? fallback.availabilityStatus
            ?? (isBlocked ? .quotaExhausted : nil)

        return QuotaSnapshot(
            source: preferred.source,
            accountIdentifier: preferred.accountIdentifier ?? fallback.accountIdentifier,
            planName: preferred.planName ?? fallback.planName,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            creditsRemaining: preferred.creditsRemaining ?? fallback.creditsRemaining,
            creditsTotal: preferred.creditsTotal ?? fallback.creditsTotal,
            updatedAt: preferred.updatedAt,
            accountValidUntil: preferred.accountValidUntil ?? fallback.accountValidUntil,
            subscriptionWillRenew: preferred.subscriptionWillRenew ?? fallback.subscriptionWillRenew,
            subscriptionStatus: preferred.subscriptionStatus ?? fallback.subscriptionStatus,
            isQuotaBlocked: isBlocked,
            availabilityStatus: availabilityStatus,
            note: preferred.note ?? fallback.note
        )
    }

    func shouldUseStatusLineSnapshotAsPrimary(_ snapshot: QuotaSnapshot) -> Bool {
        guard snapshot.source == "Claude Code StatusLine" else {
            return false
        }
        return !snapshot.orderedMetrics.isEmpty || snapshot.isQuotaBlocked == true
    }

    func recoverSecret(for account: Account) async throws -> String? {
        let credentials = try await readClaudeCodeCredentials()
        guard credentials.loggedIn else { return nil }
        let merged = mergeCredentials(preferred: credentials, fallback: credentials)
        let encoded = try encodeCredentials(merged)
        guard let expected = account.settings.identityKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else {
            return encoded
        }
        if accountIdentity(from: encoded) == expected {
            return encoded
        }
        if legacyIdentity(from: merged) == normalizeIdentityKey(expected),
           merged.userID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return encoded
        }
        return nil
    }

    func refreshSecretIfNeeded(_ secret: String) async throws -> String {
        let stored = try parseCredentials(secret)
        guard let latest = try? await readClaudeCodeCredentials(),
              latest.loggedIn,
              claudeCredentialsRepresentSameAccount(latest, stored) else {
            return secret
        }
        let merged = mergeCredentials(preferred: latest, fallback: stored)
        let encoded = try encodeCredentials(merged)
        return encoded == secret ? secret : encoded
    }

    func accountIdentity(from secret: String) -> String? {
        accountIdentityAliases(from: secret).first
    }

    func accountIdentityAliases(from secret: String) -> [String] {
        guard let credentials = try? parseCredentials(secret) else { return [] }
        var aliases: [String] = []
        if let userID = credentials.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            aliases.append("claude-code:user:\(userID)")
        }
        if let keychainCredentials = credentials.keychainCredentials?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainCredentials.isEmpty {
            aliases.append("claude-code:keychain:\(stableCredentialFingerprint(keychainCredentials))")
        }
        let method = credentials.authMethod?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        aliases.append("claude-code:\(method):\(provider)")
        return uniqueIdentityAliases(aliases)
    }

    func suggestAccountName(from secret: String) -> String? {
        guard let credentials = try? parseCredentials(secret) else { return "Claude Code" }
        if let email = readableEmail(from: credentials) {
            return email
        }
        if let userID = credentials.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            return "Claude \(String(userID.suffix(8)))"
        }
        if let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty,
           !isFirstPartyClaudeProvider(provider) {
            return "Claude Code (\(displayProviderName(from: provider)))"
        }
        return "Claude Code"
    }

}
