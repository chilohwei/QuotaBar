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

        var isHardExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow <= 0
        }
    }

    struct CachedClaudeUsage: Codable {
        let schemaVersion: Int
        let cachedAt: Date
        let snapshot: QuotaSnapshot
    }

    func parseOAuthToken(from credentials: ClaudeCodeCredentials) -> ClaudeOAuthToken? {
        for source in [credentials.keychainCredentials, credentials.claudeCredentialsJSON] {
            if let token = parseOAuthToken(fromJSONText: source) {
                return token
            }
        }
        return nil
    }

    func parseOAuthToken(fromJSONText text: String?) -> ClaudeOAuthToken? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        let access = ((oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !access.isEmpty else { return nil }
        let refresh = ((oauth["refreshToken"] as? String) ?? (oauth["refresh_token"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeOAuthToken(
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            expiresAt: parseFlexibleDate(oauth["expiresAt"] ?? oauth["expires_at"])
        )
    }

    // QuotaBar deliberately NEVER calls the OAuth token-refresh endpoint. The refresh token is
    // single-use and shared with Claude Code itself: consuming it here rotates the pair, which
    // invalidates the copy Claude Code holds and logs the user out of Claude Code — and once
    // Claude Code rotates, the copy QuotaBar holds is equally dead, producing endless "sign in
    // again" prompts. That rotation ping-pong is what forced re-logins several times a day.
    // Instead QuotaBar is a read-only passenger on the token Claude Code maintains; while that
    // token has lapsed, cached data is shown with recovery guidance, and everything self-heals
    // the next time Claude Code is used (it refreshes and persists a new token).
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

        if token.isHardExpired {
            return expiredCredentialFallback(cached)
        }

        do {
            let payload = try await requestOAuthUsage(accessToken: token.accessToken)
            let snapshot = makeOAuthUsageSnapshot(payload: payload, credentials: credentials)
            if let cacheKey {
                try? storeCachedUsage(snapshot, cacheKey: cacheKey)
                clearUsageRateLimitMarker(cacheKey)
            }
            return snapshot
        } catch OAuthUsageFetchError.unauthorized {
            // The token looked valid locally but the server rejected it — Claude Code most likely
            // rotated it moments ago. Re-read the keychain once and retry with the newer token.
            if let latest = parseOAuthToken(fromJSONText: try? readClaudeCodeKeychainCredentials()),
               latest.accessToken != token.accessToken,
               !latest.isHardExpired,
               let payload = try? await requestOAuthUsage(accessToken: latest.accessToken) {
                let snapshot = makeOAuthUsageSnapshot(payload: payload, credentials: credentials)
                if let cacheKey {
                    try? storeCachedUsage(snapshot, cacheKey: cacheKey)
                    clearUsageRateLimitMarker(cacheKey)
                }
                return snapshot
            }
            return expiredCredentialFallback(cached)
        } catch OAuthUsageFetchError.rateLimited(let retryAfter) {
            // `/usage` is throttling us — remember it so the panel can explain the slower refreshes.
            setUsageRateLimitMarker(cacheKey)
            if let fallback = staleLiveFallback(cached) {
                return fallback.replacing(availabilityStatus: .authRateLimited)
            }
            throw ProviderError.rateLimited(tool: .claudeCode, retryAfter: retryAfter)
        } catch {
            // Transient network problem — fall through to the stale-but-honest fallback below.
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

    /// Cached usage shown while Claude Code's access token has lapsed, labeled with how it
    /// recovers on its own (using Claude Code once mints a fresh token QuotaBar can ride).
    func expiredCredentialFallback(_ cached: CachedClaudeUsage?) -> QuotaSnapshot? {
        guard let fallback = historicalLiveFallback(cached),
              !fallback.orderedMetrics.isEmpty else {
            return nil
        }
        return fallback.replacing(note: QuotaNoteCatalog.claudeCredentialsAwaitingClaudeCode)
    }

    func loadCachedOAuthUsage(credentials: ClaudeCodeCredentials) -> CachedClaudeUsage? {
        usageCacheKey(credentials).flatMap { try? loadCachedUsage(cacheKey: $0) }
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

    /// True when `/usage` recently answered 429; used to slow polling and surface the
    /// actionable `usageRateLimitedNote` while Anthropic is throttling us.
    func isAuthRateLimited(_ credentials: ClaudeCodeCredentials, now: Date = Date()) -> Bool {
        guard let cacheKey = usageCacheKey(credentials) else { return false }
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
