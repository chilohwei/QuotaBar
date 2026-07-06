import Foundation

// Self-renewal of a lapsed Claude Code keychain token.
//
// QuotaBar treats Claude Code as the owner of these credentials and never races it for the
// single-use refresh token: rotating the pair while the CLI is maintaining it invalidates the
// copy the CLI holds and logs the user out — the ping-pong that once forced re-logins several
// times a day. But the owner doesn't always show up: GUI clients (the Claude Code desktop app)
// keep their own credential store and never renew this keychain item, and `claude auth status`
// merely reports state without refreshing. Left alone, the keychain token dies 8 hours after
// the last CLI use and QuotaBar is stuck on cached data.
//
// So the policy is: give the CLI first claim, then take over. Only once the token has sat
// hard-expired past `selfRefreshGrace` — proof no CLI is actively maintaining it — QuotaBar
// renews the pair against the exact credentials currently in the keychain and immediately
// writes the rotated pair back, so the CLI's next launch rides the fresh token just like
// QuotaBar rides its own.
extension ClaudeCodeProvider {
    struct RefreshedOAuthToken {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date?
    }

    /// Renews the keychain token pair when it has lapsed with no other maintainer in sight.
    /// Returns a usable access token — freshly rotated, or the keychain's own if some other
    /// maintainer beat us to the renewal — or nil when the fallback note should stay.
    func selfRefreshHardExpiredToken(
        matching expired: ClaudeOAuthToken,
        intent: RefreshIntent,
        now: Date = Date()
    ) async -> ClaudeOAuthToken? {
        guard Self.shouldAttemptSelfRefresh(
            expiresAt: expired.expiresAt,
            blockedUntil: selfRefreshBlockedUntil(),
            intent: intent,
            now: now
        ) else {
            return nil
        }

        // Rotate only the exact pair sitting in the keychain right now. The live re-read both
        // picks up a token some other maintainer just minted (ride it, no rotation) and
        // guarantees we never consume a refresh token from a stale stored copy.
        guard let live = parseOAuthToken(fromJSONText: try? readClaudeCodeKeychainCredentials()) else {
            return nil
        }
        if !live.isHardExpired {
            return live
        }
        guard live.accessToken == expired.accessToken,
              let refreshToken = live.refreshToken else {
            // The keychain holds a different (also expired) pair than the one this fetch started
            // from — likely another account was activated mid-flight. Not ours to rotate.
            return nil
        }

        do {
            let refreshed = try await requestTokenRefresh(refreshToken: refreshToken)
            // Write-back must not be skipped: the old refresh token is consumed the moment the
            // endpoint answers, so a keychain still holding it would strand the CLI. If the write
            // fails there is nothing better to do than still use the fresh token for this fetch.
            try? writeRefreshedOAuthToken(refreshed)
            clearSelfRefreshBlock()
            return ClaudeOAuthToken(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: refreshed.expiresAt
            )
        } catch OAuthUsageFetchError.unauthorized {
            setSelfRefreshBlock(until: now.addingTimeInterval(Self.selfRefreshDeadGrantRetryFloor))
            return nil
        } catch {
            setSelfRefreshBlock(until: now.addingTimeInterval(Self.selfRefreshRetryFloor))
            return nil
        }
    }

    /// Pure gate for `selfRefreshHardExpiredToken`: expired past the grace window, and not inside
    /// a failure-backoff window (manual refreshes bypass the backoff, never the grace — the grace
    /// is what keeps QuotaBar from stealing an in-flight CLI rotation).
    static func shouldAttemptSelfRefresh(
        expiresAt: Date?,
        blockedUntil: Date?,
        intent: RefreshIntent,
        now: Date = Date()
    ) -> Bool {
        guard let expiresAt, now.timeIntervalSince(expiresAt) >= selfRefreshGrace else {
            return false
        }
        if intent.bypassesAppBackoff {
            return true
        }
        if let blockedUntil, blockedUntil > now {
            return false
        }
        return true
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

    /// Merges the rotated tokens back into the keychain credentials, preserving every other field.
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

    // The keychain item is a single machine-global resource, so the failure backoff is one
    // global marker rather than per-account state.
    func selfRefreshBlockPath() -> String {
        AppPaths.quotaCacheDirectory.appendingPathComponent("claude-token-refresh-block").path
    }

    func selfRefreshBlockedUntil() -> Date? {
        guard let text = try? fileService.readText(at: selfRefreshBlockPath()),
              let epoch = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    func setSelfRefreshBlock(until: Date) {
        try? fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        try? fileService.writeText(
            String(until.timeIntervalSince1970),
            to: selfRefreshBlockPath(),
            permissions: 0o600
        )
    }

    func clearSelfRefreshBlock() {
        try? fileService.removeItemIfExists(at: selfRefreshBlockPath())
    }
}
