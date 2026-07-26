import Foundation

extension ClaudeCodeProvider {
    func importCurrentCredentials() async throws -> String {
        let credentials = try await readClaudeCodeCredentials()
        guard credentials.loggedIn else {
            throw ProviderError.loginRequired(tool: .claudeCode, message: claudeLoginRequiredMessage)
        }
        return try encodeCredentials(credentials)
    }

    func authenticateViaBrowser() async throws -> String {
        do {
            let previous = try? await readClaudeCodeCredentials()
            await MainActor.run {
                LoginFlowProgress.shared.begin(method: .browser, timeout: 300)
            }
            try await runClaudeAuthLogin(timeout: 300)
            let credentials = try await readClaudeCodeCredentials()
            guard credentials.loggedIn else {
                throw ProviderError.loginRequired(tool: .claudeCode, message: claudeLoginRequiredMessage)
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
            throw ProviderError.loginRequired(tool: .claudeCode, message: claudeLoginRequiredMessage)
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

        // Claude Code owns the live credentials. When the installed account already matches the
        // one being activated (every app launch re-applies the active selection), activation must
        // NOT touch the keychain: the write is a delete + recreate with our stored snapshot, which
        // races Claude Code's own token maintenance and can replace a fresh token with a stale
        // copy — the root cause of "sign in again" loops and surprise Claude Code logouts.
        if let previous, previous.loggedIn, claudeCredentialsRepresentSameAccount(previous, stored) {
            try installQuotaBarStatusLine()
            return
        }

        var replacedCredentials = false
        if hasRestorableClaudeArtifacts(stored) {
            try restoreClaudeArtifacts(from: stored)
            replacedCredentials = true
        }
        if let keychainCredentials = stored.keychainCredentials?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainCredentials.isEmpty {
            try writeClaudeCodeKeychainCredentials(keychainCredentials)
            // The keychain swap alone leaves `~/.claude.json`'s cached `oauthAccount` describing
            // the previous account — which is where `claude auth status` reads identity from, so
            // both the CLI and the verification below would keep reporting the old login.
            try writeClaudeOAuthAccount(from: stored)
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
        let liveCredentials = try? await readClaudeCodeCredentials()
        let isLiveCliAccount = liveCredentials.map {
            claudeCredentialsRepresentSameAccount($0, storedCredentials)
        } ?? false
        let credentials: ClaudeCodeCredentials
        if isLiveCliAccount, let liveCredentials {
            credentials = mergeCredentials(preferred: liveCredentials, fallback: storedCredentials)
        } else {
            credentials = storedCredentials
        }

        let now = Date()
        // The statusLine snapshot and session transcripts describe whichever account the CLI is
        // signed into right now. For any other stored account they are someone else's numbers,
        // so that account must rely on its own OAuth token and cache exclusively.
        let statusLineLoad = isLiveCliAccount ? (try? loadStatusLineSnapshot()) : nil
        let rateLimitEvent = isLiveCliAccount
            ? loadActiveRateLimitEvent(status: statusLineLoad?.status, now: now)
            : nil
        let cachedOAuthSnapshot = loadCachedOAuthUsage(credentials: credentials)
            .flatMap { cached -> QuotaSnapshot? in
                guard now.timeIntervalSince(cached.cachedAt) <= Self.historicalFillMaxAge else { return nil }
                return historicalLiveFallback(cached)
            }
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

        // With live usage unavailable, an account the CLI is NOT signed into has no statusLine
        // to fall back on — its own historical cache is all there is.
        if !isLiveCliAccount {
            let fallback = cachedOAuthSnapshot ?? statusLineSnapshot
            if isAuthRateLimited(credentials, now: now) {
                return fallback.replacing(
                    note: Self.usageRateLimitedNote,
                    availabilityStatus: .authRateLimited
                )
            }
            return fallback
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
        if accountIdentityAliases(from: encoded)
            .map(normalizeIdentityKey)
            .contains(normalizeIdentityKey(expected)) {
            return encoded
        }
        // Accounts stored before identity moved off the machine-scoped `userID` still carry a
        // `claude-code:user:<installation ID>` key. Accept it until the bootstrap migration
        // (and the per-refresh identity update) re-keys them to account-scoped identities.
        if let userID = merged.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty,
           normalizeIdentityKey(expected) == normalizeIdentityKey("claude-code:user:\(userID)") {
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
        let latest = try? await readClaudeCodeCredentials()
        if let latest, latest.loggedIn, claudeCredentialsRepresentSameAccount(latest, stored) {
            let merged = mergeCredentials(preferred: latest, fallback: stored)
            let encoded = try encodeCredentials(merged)
            return encoded == secret ? secret : encoded
        }
        // The CLI is signed into a different account (or none), so nothing else maintains this
        // stored token pair — the CLI lost its copy the moment the keychain was overwritten.
        // QuotaBar is its only holder, making rotation race-free, and without it the account
        // would go permanently stale ~8 hours after the last switch away from it.
        if let refreshed = await refreshDetachedStoredCredentials(
            stored,
            liveKeychainCredentials: latest?.keychainCredentials
        ) {
            return try encodeCredentials(refreshed)
        }
        return secret
    }

    func accountIdentity(from secret: String) -> String? {
        accountIdentityAliases(from: secret).first
    }

    // `~/.claude.json`'s `userID` is deliberately absent here: it is an installation-scoped
    // random ID the CLI never rotates on login, so it is identical for every account on this
    // machine and made a second added account dedupe-match (and overwrite) the first one.
    func accountIdentityAliases(from secret: String) -> [String] {
        guard let credentials = try? parseCredentials(secret) else { return [] }
        var aliases: [String] = []
        if let accountUuid = claudeAccountUuid(from: credentials) {
            aliases.append("claude-code:account:\(accountUuid)")
        }
        if let email = claudeAccountEmail(from: credentials) {
            aliases.append("claude-code:email:\(email)")
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
        // Fall back to the account UUID, never the installation-scoped `userID`: that value is
        // shared by every account on this machine, so names derived from it are identical.
        if let accountUuid = claudeAccountUuid(from: credentials) {
            return "Claude \(String(accountUuid.suffix(8)))"
        }
        if let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty,
           !isFirstPartyClaudeProvider(provider) {
            return "Claude Code (\(displayProviderName(from: provider)))"
        }
        return "Claude Code"
    }

}
