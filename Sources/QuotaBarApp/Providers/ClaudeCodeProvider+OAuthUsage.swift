import Foundation

extension ClaudeCodeProvider {
    func shouldFetchOAuthUsage(_ credentials: ClaudeCodeCredentials) -> Bool {
        if credentials.authMethod == "api_key" {
            return false
        }
        if thirdPartyProviderName(credentials: credentials, status: nil) != nil {
            return false
        }
        let rawProvider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawProvider == "api_key" {
            return false
        }
        if isFirstPartyClaudeProvider(credentials.apiProvider) {
            return true
        }
        let authMethod = credentials.authMethod?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return authMethod == "oauth" || authMethod == "claude.ai" || authMethod == "claudeai"
    }

    struct ClaudeOAuthToken {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    struct RefreshedOAuthToken {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date?
    }

    struct CachedClaudeUsage: Codable {
        let schemaVersion: Int
        let cachedAt: Date
        let snapshot: QuotaSnapshot
    }

    func parseOAuthToken(from credentials: ClaudeCodeCredentials) -> ClaudeOAuthToken? {
        for source in [credentials.keychainCredentials, credentials.claudeCredentialsJSON] {
            guard let text = source?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = object["claudeAiOauth"] as? [String: Any] else {
                continue
            }
            let access = ((oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !access.isEmpty else { continue }
            let refresh = ((oauth["refreshToken"] as? String) ?? (oauth["refresh_token"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ClaudeOAuthToken(
                accessToken: access,
                refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
                expiresAt: parseFlexibleDate(oauth["expiresAt"] ?? oauth["expires_at"])
            )
        }
        return nil
    }

    func fetchOAuthUsageSnapshot(
        credentials: ClaudeCodeCredentials,
        intent: RefreshIntent
    ) async throws -> QuotaSnapshot? {
        guard shouldFetchOAuthUsage(credentials) else {
            return nil
        }

        let cacheKey = usageCacheKey(credentials)
        let cached = cacheKey.flatMap { try? loadCachedUsage(cacheKey: $0) }
        guard let token = parseOAuthToken(from: credentials) else {
            return staleLiveFallback(cached)
        }

        // Collapse bursty triggers: a very recent live snapshot is reused as-is, so QuotaBar does
        // not re-hit the endpoint (and trip its per-account rate limit) several times a minute.
        if !intent.bypassesProviderCache,
           isAuthRateLimited(credentials),
           let fallback = staleLiveFallback(cached) {
            return fallback.replacing(availabilityStatus: .authRateLimited)
        }

        if !intent.bypassesProviderCache,
           let cached,
           Date().timeIntervalSince(cached.cachedAt) < Self.liveUsageMinFetchInterval {
            return cached.snapshot
        }

        let isExpired = token.expiresAt.map { $0.timeIntervalSinceNow <= Self.oauthTokenExpiryMargin } ?? false
        var accessToken = token.accessToken
        var didRefresh = false
        if isExpired {
            // The token is dead; refreshing it is the only way to get live data. If the refresh is
            // in cooldown (a recent attempt failed), don't call either endpoint — a dead token only
            // yields 401s and hammering keeps the auth endpoint throttled. Show honest stale data.
            guard let refreshed = try await refreshAccessTokenIfAllowed(
                refreshToken: token.refreshToken,
                cacheKey: cacheKey,
                intent: intent
            ) else {
                // Automatic retries have run their course; QuotaBar cannot revive this
                // token on its own, so escalate to an explicit re-login prompt.
                if hasExhaustedTokenRefreshAttempts(cacheKey, intent: intent) {
                    throw ProviderError.tokenExpired(tool: .claudeCode)
                }
                return staleLiveFallback(cached)
            }
            accessToken = refreshed
            didRefresh = true
        }

        do {
            let payload = try await requestOAuthUsage(accessToken: accessToken)
            let snapshot = makeOAuthUsageSnapshot(payload: payload, credentials: credentials)
            if let cacheKey {
                try? storeCachedUsage(snapshot, cacheKey: cacheKey)
                clearUsageRateLimitMarker(cacheKey)
                clearTokenRefreshBackoff(cacheKey)
            }
            return snapshot
        } catch OAuthUsageFetchError.unauthorized where !didRefresh {
            // Token looked locally valid but was rejected — refresh once (if allowed) and retry.
            do {
                guard let refreshed = try await refreshAccessTokenIfAllowed(
                    refreshToken: token.refreshToken,
                    cacheKey: cacheKey,
                    intent: intent
                ) else {
                    if hasExhaustedTokenRefreshAttempts(cacheKey, intent: intent) {
                        throw ProviderError.tokenExpired(tool: .claudeCode)
                    }
                    return staleLiveFallback(cached)
                }
                let payload = try await requestOAuthUsage(accessToken: refreshed)
                let snapshot = makeOAuthUsageSnapshot(payload: payload, credentials: credentials)
                if let cacheKey {
                    try? storeCachedUsage(snapshot, cacheKey: cacheKey)
                    clearUsageRateLimitMarker(cacheKey)
                    clearTokenRefreshBackoff(cacheKey)
                }
                return snapshot
            } catch OAuthUsageFetchError.unauthorized {
                throw ProviderError.tokenExpired(tool: .claudeCode)
            } catch OAuthUsageFetchError.rateLimited(let retryAfter) {
                setUsageRateLimitMarker(cacheKey)
                if let fallback = staleLiveFallback(cached) {
                    return fallback.replacing(availabilityStatus: .authRateLimited)
                }
                throw ProviderError.rateLimited(tool: .claudeCode, retryAfter: retryAfter)
            } catch let error as ProviderError {
                // tokenExpired and friends must reach the UI, not degrade into stale data.
                throw error
            } catch {
                return staleLiveFallback(cached)
            }
        } catch OAuthUsageFetchError.unauthorized {
            throw ProviderError.tokenExpired(tool: .claudeCode)
        } catch OAuthUsageFetchError.rateLimited(let retryAfter) {
            // `/usage` is throttling us — remember it so the panel can show actionable guidance.
            setUsageRateLimitMarker(cacheKey)
            if let fallback = staleLiveFallback(cached) {
                return fallback.replacing(availabilityStatus: .authRateLimited)
            }
            throw ProviderError.rateLimited(tool: .claudeCode, retryAfter: retryAfter)
        } catch {
            // fall through to the stale-but-honest fallback below
        }

        return staleLiveFallback(cached)
    }

    /// The last real `/usage` value from the OAuth fallback path, labeled with its age while recent
    /// enough to be meaningful. A cache whose windows have all reset carries no information.
    func staleLiveFallback(_ cached: CachedClaudeUsage?) -> QuotaSnapshot? {
        guard let cached,
              Date().timeIntervalSince(cached.cachedAt) <= Self.liveUsageStaleMax,
              let fallback = historicalLiveFallback(cached),
              !fallback.orderedMetrics.isEmpty else {
            return nil
        }
        return fallback
    }

    func historicalLiveFallback(_ cached: CachedClaudeUsage?) -> QuotaSnapshot? {
        guard let cached else { return nil }
        let minutes = max(1, Int(Date().timeIntervalSince(cached.cachedAt) / 60))
        return cached.snapshot
            .removingExpiredWindows()
            .replacing(
                source: "Claude Code OAuth Cache",
                updatedAt: cached.cachedAt,
                note: QuotaNoteCatalog.claudeStaleLiveData(minutes: minutes)
            )
    }

    func loadCachedOAuthUsage(credentials: ClaudeCodeCredentials) -> CachedClaudeUsage? {
        usageCacheKey(credentials).flatMap { try? loadCachedUsage(cacheKey: $0) }
    }

    /// Refreshes the access token unless a recent refresh failed and we're still in its cooldown.
    /// On failure it sets a cooldown so the app stops hammering the auth endpoint every poll cycle
    /// (which would otherwise sustain the very rate limit that's blocking recovery).
    func refreshAccessTokenIfAllowed(
        refreshToken: String?,
        cacheKey: String?,
        intent: RefreshIntent = .background
    ) async throws -> String? {
        if Self.shouldBlockTokenRefresh(
            until: tokenRefreshBlockedUntil(cacheKey),
            intent: intent
        ) {
            return nil
        }
        do {
            let access = try await refreshAndPersistToken(refreshToken: refreshToken)
            clearTokenRefreshBackoff(cacheKey)
            return access
        } catch OAuthUsageFetchError.unauthorized {
            clearTokenRefreshBackoff(cacheKey)
            throw ProviderError.tokenExpired(tool: .claudeCode)
        } catch {
            let isFirstFailure = tokenRefreshBackoffState(cacheKey) == nil
            setTokenRefreshBackoff(cacheKey)
            guard isFirstFailure else { return nil }

            // The very first failure gets one immediate silent retry — transient throttles
            // often clear at once, and waiting a full cooldown would leave the panel stale
            // for no reason. If the retry also fails, the caller escalates to the
            // re-login prompt right away instead of after another cooldown.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let access = try await refreshAndPersistToken(refreshToken: refreshToken)
                clearTokenRefreshBackoff(cacheKey)
                return access
            } catch OAuthUsageFetchError.unauthorized {
                clearTokenRefreshBackoff(cacheKey)
                throw ProviderError.tokenExpired(tool: .claudeCode)
            } catch {
                setTokenRefreshBackoff(cacheKey)
                return nil
            }
        }
    }

    static func shouldBlockTokenRefresh(
        until: Date?,
        intent: RefreshIntent,
        now: Date = Date()
    ) -> Bool {
        guard intent != .manual else { return false }
        guard let until else { return false }
        return until > now
    }

    func requestTokenRefresh(refreshToken: String) async throws -> RefreshedOAuthToken {
        var request = URLRequest(url: Self.oauthTokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.oauthUsageUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientID
        ])

        let (data, response) = try await Self.liveSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthUsageFetchError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = (object["access_token"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !access.isEmpty else {
                throw OAuthUsageFetchError.invalidResponse
            }
            let newRefresh = (object["refresh_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expiresAt = number(object["expires_in"]).map { Date().addingTimeInterval($0) }
            return RefreshedOAuthToken(
                accessToken: access,
                refreshToken: (newRefresh?.isEmpty == false) ? newRefresh! : refreshToken,
                expiresAt: expiresAt
            )
        case 400:
            // OAuth error responses use 400 for permanently dead grants (RFC 6749 §5.2).
            // Treat those as unauthorized so the UI says "sign in again" instead of
            // silently retrying a token that can never work.
            if Self.isPermanentTokenRefreshFailure(body: data) {
                throw OAuthUsageFetchError.unauthorized
            }
            throw OAuthUsageFetchError.httpStatus(http.statusCode)
        case 401, 403:
            throw OAuthUsageFetchError.unauthorized
        case 429:
            throw OAuthUsageFetchError.rateLimited(retryAfter: QuotaHTTPClient.retryAfterDeadline(from: http))
        default:
            throw OAuthUsageFetchError.httpStatus(http.statusCode)
        }
    }

    static func isPermanentTokenRefreshFailure(body: Data) -> Bool {
        guard let text = String(data: body, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("invalid_grant")
            || text.contains("invalid_request")
            || text.contains("invalid refresh token")
    }

    @discardableResult
    func refreshAndPersistToken(refreshToken: String?) async throws -> String {
        guard let refreshToken, !refreshToken.isEmpty else {
            throw OAuthUsageFetchError.unauthorized
        }
        let refreshed = try await requestTokenRefresh(refreshToken: refreshToken)
        try? writeRefreshedOAuthToken(refreshed)
        return refreshed.accessToken
    }

    /// Merges rotated tokens back into the keychain credentials, preserving every other field.
    func writeRefreshedOAuthToken(_ token: RefreshedOAuthToken) throws {
        guard let text = try readClaudeCodeKeychainCredentials()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let data = text.data(using: .utf8),
              var full = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = full["claudeAiOauth"] as? [String: Any] else {
            return
        }
        oauth["accessToken"] = token.accessToken
        oauth["refreshToken"] = token.refreshToken
        if let expiresAt = token.expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        full["claudeAiOauth"] = oauth
        let newData = try JSONSerialization.data(withJSONObject: full)
        guard let newText = String(data: newData, encoding: .utf8) else { return }
        try writeClaudeCodeKeychainCredentials(newText)
    }

    func usageCacheKey(_ credentials: ClaudeCodeCredentials) -> String? {
        if let userID = credentials.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            return "claude-usage-" + stableCredentialFingerprint("user:\(userID)")
        }
        if let keychainCredentials = credentials.keychainCredentials?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainCredentials.isEmpty {
            return "claude-usage-" + stableCredentialFingerprint(keychainCredentials)
        }
        return nil
    }

    func usageCachePath(cacheKey: String) -> String {
        AppPaths.quotaCacheDirectory.appendingPathComponent("\(cacheKey).json").path
    }

    func loadCachedUsage(cacheKey: String) throws -> CachedClaudeUsage {
        let text = try fileService.readText(at: usageCachePath(cacheKey: cacheKey))
        guard let data = text.data(using: .utf8) else {
            throw ProviderError.cacheCorrupted(tool: .claudeCode)
        }
        return try JSONDecoder().decode(CachedClaudeUsage.self, from: data)
    }

    func storeCachedUsage(_ snapshot: QuotaSnapshot, cacheKey: String) throws {
        try fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        let cached = CachedClaudeUsage(schemaVersion: 1, cachedAt: Date(), snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cached)
        try fileService.writeText(
            String(data: data, encoding: .utf8) ?? "{}",
            to: usageCachePath(cacheKey: cacheKey),
            permissions: 0o600
        )
    }

    func tokenRefreshBackoffPath(_ cacheKey: String) -> String {
        AppPaths.quotaCacheDirectory.appendingPathComponent("\(cacheKey)-refresh-backoff").path
    }

    struct TokenRefreshBackoff {
        let attempts: Int
        let until: Date
    }

    /// Cooldown for the Nth consecutive failed refresh: base × 2^(n-1), capped. Pure so the
    /// escalation curve can be verified without touching the filesystem-backed backoff state.
    static func escalatedRefreshCooldown(attempts: Int) -> TimeInterval {
        min(
            tokenRefreshCooldown * pow(2, Double(max(attempts, 1) - 1)),
            tokenRefreshCooldownMax
        )
    }

    /// Reads the persisted backoff. Understands the current JSON form `{"attempts":N,"until":epoch}`
    /// and falls back to the legacy bare-epoch form so an old file still blocks correctly.
    func tokenRefreshBackoffState(_ cacheKey: String?) -> TokenRefreshBackoff? {
        guard let cacheKey,
              let text = try? fileService.readText(at: tokenRefreshBackoffPath(cacheKey)) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let until = number(object["until"]) {
            let attempts = number(object["attempts"]).map { Int($0) } ?? 1
            return TokenRefreshBackoff(attempts: max(attempts, 1), until: Date(timeIntervalSince1970: until))
        }
        if let epoch = Double(trimmed) {
            return TokenRefreshBackoff(attempts: 1, until: Date(timeIntervalSince1970: epoch))
        }
        return nil
    }

    func tokenRefreshBlockedUntil(_ cacheKey: String?) -> Date? {
        tokenRefreshBackoffState(cacheKey)?.until
    }

    /// True once refresh retries have failed often enough for the given trigger that waiting
    /// longer is pointless without a fresh sign-in.
    func hasExhaustedTokenRefreshAttempts(_ cacheKey: String?, intent: RefreshIntent) -> Bool {
        Self.shouldPromptRelogin(
            attempts: tokenRefreshBackoffState(cacheKey)?.attempts ?? 0,
            intent: intent
        )
    }

    static func shouldPromptRelogin(attempts: Int, intent: RefreshIntent) -> Bool {
        guard attempts >= 1 else { return false }
        switch intent {
        case .manual, .visible:
            // The user is looking at (or explicitly asked for) fresh data right now.
            return true
        case .background:
            return attempts >= backgroundRefreshAttemptsBeforeReloginHint
        }
    }

    func setTokenRefreshBackoff(_ cacheKey: String?) {
        guard let cacheKey else { return }
        try? fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        // Escalate on consecutive failures: base × 2^(n-1), capped. A persistently rate-limited
        // auth endpoint (HTTP 429 with a misleading `retry-after: 0`) needs progressively longer
        // room to recover; a fixed short cooldown just keeps the limit alive. `clearTokenRefreshBackoff`
        // resets the count after any successful refresh.
        let attempts = (tokenRefreshBackoffState(cacheKey)?.attempts ?? 0) + 1
        let until = Date().addingTimeInterval(Self.escalatedRefreshCooldown(attempts: attempts)).timeIntervalSince1970
        let json = "{\"attempts\":\(attempts),\"until\":\(until)}"
        try? fileService.writeText(json, to: tokenRefreshBackoffPath(cacheKey), permissions: 0o600)
    }

    func clearTokenRefreshBackoff(_ cacheKey: String?) {
        guard let cacheKey else { return }
        try? fileService.removeItemIfExists(at: tokenRefreshBackoffPath(cacheKey))
    }

    func usageRateLimitMarkerPath(_ cacheKey: String) -> String {
        AppPaths.quotaCacheDirectory.appendingPathComponent("\(cacheKey)-usage-429").path
    }

    /// Records that the `/usage` endpoint just answered 429, so the panel can explain the throttle.
    func setUsageRateLimitMarker(_ cacheKey: String?) {
        guard let cacheKey else { return }
        try? fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        try? fileService.writeText(
            String(Date().timeIntervalSince1970),
            to: usageRateLimitMarkerPath(cacheKey),
            permissions: 0o600
        )
    }

    func clearUsageRateLimitMarker(_ cacheKey: String?) {
        guard let cacheKey else { return }
        try? fileService.removeItemIfExists(at: usageRateLimitMarkerPath(cacheKey))
    }

    /// True when the OAuth fallback path is currently blocked by Anthropic rate limiting, either
    /// because the token refresh is in an active 429 backoff or `/usage` recently returned 429.
    /// Used to surface the actionable `usageRateLimitedNote` when the fallback cannot be refreshed.
    func isAuthRateLimited(_ credentials: ClaudeCodeCredentials, now: Date = Date()) -> Bool {
        guard let cacheKey = usageCacheKey(credentials) else { return false }
        if let until = tokenRefreshBlockedUntil(cacheKey), until > now {
            return true
        }
        if let text = try? fileService.readText(at: usageRateLimitMarkerPath(cacheKey)),
           let epoch = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return now.timeIntervalSince(Date(timeIntervalSince1970: epoch)) <= Self.usageRateLimitMarkerFreshness
        }
        return false
    }

    func requestOAuthUsage(accessToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: Self.oauthUsageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.oauthUsageUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await Self.liveSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthUsageFetchError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OAuthUsageFetchError.invalidResponse
            }
            return payload
        case 401, 403:
            throw OAuthUsageFetchError.unauthorized
        case 429:
            throw OAuthUsageFetchError.rateLimited(retryAfter: QuotaHTTPClient.retryAfterDeadline(from: http))
        default:
            throw OAuthUsageFetchError.httpStatus(http.statusCode)
        }
    }

    func makeOAuthUsageSnapshot(
        payload: [String: Any],
        credentials: ClaudeCodeCredentials
    ) -> QuotaSnapshot {
        let primary = parseOAuthUsageWindow(
            usageWindowDictionary(in: payload, keys: Self.fiveHourLimitKeys),
            label: "5h"
        )
        let secondary = parseOAuthUsageWindow(
            usageWindowDictionary(in: payload, keys: Self.weeklyLimitKeys),
            label: "7d"
        )

        return QuotaSnapshot(
            source: "Claude Code OAuth",
            accountIdentifier: readableIdentity(from: credentials),
            planName: planName(credentials: credentials, status: nil),
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(),
            accountValidUntil: nil,
            subscriptionWillRenew: nil,
            subscriptionStatus: nil,
            isQuotaBlocked: isQuotaBlocked(primary: primary, secondary: secondary),
            availabilityStatus: isQuotaBlocked(primary: primary, secondary: secondary) == true ? .quotaExhausted : nil,
            note: nil
        )
    }

    func shouldUseStatusLineSnapshot(_ status: [String: Any]?, settingsJSON: String?) -> Bool {
        guard status != nil else { return false }
        if hasRateLimitWindow(status) {
            return true
        }
        return quotaBarStatusLineIsInstalled(settingsJSON: settingsJSON)
    }

    func hasRateLimitWindow(_ status: [String: Any]?) -> Bool {
        makeWindow(status: status, keys: Self.fiveHourLimitKeys, label: "5h", rejectExpiredWindows: false) != nil
            || makeWindow(status: status, keys: Self.weeklyLimitKeys, label: "7d", rejectExpiredWindows: false) != nil
    }

    func usageWindowDictionary(in payload: [String: Any], keys: Set<String>) -> [String: Any]? {
        if let window = firstDictionary(in: payload, keys: keys) {
            return window
        }

        for containerKey in ["rate_limits", "rateLimits", "usage", "plan_usage", "planUsage", "limits"] {
            guard let container = payload[containerKey] as? [String: Any],
                  let window = firstDictionary(in: container, keys: keys) else {
                continue
            }
            return window
        }
        return nil
    }

}
