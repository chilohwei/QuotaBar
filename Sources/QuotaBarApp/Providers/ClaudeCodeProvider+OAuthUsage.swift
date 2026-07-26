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
        // Scopes granted to the stored pair; a refresh grant must ask for the same set.
        var scopes: [String]? = nil

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
        let scopes = (oauth["scopes"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ClaudeOAuthToken(
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            expiresAt: parseFlexibleDate(oauth["expiresAt"] ?? oauth["expires_at"]),
            scopes: (scopes?.isEmpty == false) ? scopes : nil
        )
    }

    // While the keychain token is alive (or only just expired), QuotaBar is a read-only passenger
    // on it: the refresh token is single-use and shared with Claude Code, and racing the CLI for
    // the rotation is what once forced re-logins several times a day. But the CLI isn't always
    // there to renew — GUI clients keep their own credential store and never touch this keychain
    // item — so once the token has sat expired past a grace window, QuotaBar renews the pair
    // itself and writes it back for both sides to ride (see ClaudeCodeProvider+TokenRefresh).
    // Until that kicks in, cached data is shown with recovery guidance.
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

        var activeToken = token
        if token.isHardExpired {
            guard let renewed = await selfRefreshHardExpiredToken(matching: token, intent: intent) else {
                return expiredCredentialFallback(cached)
            }
            activeToken = renewed
        }

        do {
            let payload = try await requestOAuthUsage(accessToken: activeToken.accessToken)
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
               latest.accessToken != activeToken.accessToken,
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

    // Keyed on account-scoped identity. The old key used `~/.claude.json`'s `userID`, which the
    // CLI mints once per installation — every account on the machine landed in the same cache
    // file and inherited each other's numbers.
    func usageCacheKey(_ credentials: ClaudeCodeCredentials) -> String? {
        if let accountUuid = claudeAccountUuid(from: credentials) {
            return "claude-usage-" + stableCredentialFingerprint("account:\(accountUuid)")
        }
        if let email = claudeAccountEmail(from: credentials) {
            return "claude-usage-" + stableCredentialFingerprint("email:\(email)")
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
        let secondary = weekly.first
        let tertiary = weekly.dropFirst().first

        return QuotaSnapshot(
            source: "Claude Code OAuth",
            accountIdentifier: readableIdentity(from: credentials),
            planName: planName(credentials: credentials, status: nil),
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
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
            guard let percent = number(entry["percent"]) ?? number(entry["utilization"]) else {
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
            case "weekly":
                let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
                let modelName = (model?["display_name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = (modelName?.isEmpty == false) ? "7d·\(modelName!)" : "7d"
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
