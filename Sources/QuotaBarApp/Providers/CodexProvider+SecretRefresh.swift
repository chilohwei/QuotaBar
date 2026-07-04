import Foundation

extension CodexProvider {
    func refreshSecretIfNeeded(_ secret: String) async throws -> String {
        try await refreshSecret(secret, force: false)
    }

    func refreshSecret(_ secret: String, force: Bool) async throws -> String {
        guard let data = secret.data(using: .utf8) else {
            throw ProviderError.credentialParsingFailed(tool: .codex)
        }

        let parsed = try parseCredentialEnvelope(data: data)
        let credentials = parsed.credentials
        guard let accessToken = credentials.accessToken, !accessToken.isEmpty else {
            return secret
        }
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return secret
        }

        let mustRefresh = force || accessTokenExpiresSoon(accessToken)
        let shouldRefreshForIDToken = credentials.idToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        let shouldRefresh: Bool
        if mustRefresh {
            shouldRefresh = true
        } else if shouldRefreshForIDToken {
            shouldRefresh = credentials.lastRefresh.map {
                Date().timeIntervalSince($0) > tokenRefreshInterval
            } ?? true
        } else if let lastRefresh = credentials.lastRefresh {
            shouldRefresh = Date().timeIntervalSince(lastRefresh) > tokenRefreshInterval
        } else {
            shouldRefresh = true
        }

        guard shouldRefresh else { return secret }

        do {
            let refreshed = try await refreshOAuthCredentials(credentials)
            let updated = try writeCredentials(refreshed, into: parsed.root)
            return String(data: updated, encoding: .utf8) ?? secret
        } catch {
            // 网络抖动或 SSL 握手故障时，先沿用现有 token，避免整卡片直接进入错误态。
            // 后续 fetchQuota 仍会执行并可使用缓存兜底。
            if !mustRefresh && shouldTreatAsTransientNetworkError(error) {
                return secret
            }
            throw error
        }
    }

    func refreshOAuthCredentials(_ credentials: CodexCredentials) async throws -> CodexCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return credentials
        }

        let url = URL(string: "https://auth.openai.com/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let body: [String: String] = [
            "client_id": refreshClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await tokenRefreshResponse(for: request)

        if http.statusCode == 400 || http.statusCode == 401 {
            let code = extractErrorCode(from: data)
            switch code?.lowercased() {
            case "refresh_token_reused":
                throw ProviderError.loginRequired(tool: .codex, message: "Codex refresh token 已被使用，请重新登录")
            case "refresh_token_invalidated":
                throw ProviderError.loginRequired(tool: .codex, message: "Codex refresh token 已失效，请重新登录")
            case "invalid_grant", "invalid_request":
                throw ProviderError.loginRequired(tool: .codex, message: "Codex refresh token 无效，请重新登录")
            default:
                throw ProviderError.loginRequired(tool: .codex, message: "Codex refresh token 已过期，请重新登录")
            }
        }

        if isRetryableHTTPStatus(http.statusCode) {
            throw QuotaHTTPError(
                operation: "Codex token 刷新",
                statusCode: http.statusCode,
                isRetryable: true
            )
        }

        guard http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.network("Codex token 刷新失败，HTTP \(http.statusCode)")
        }

        return CodexCredentials(
            apiKey: credentials.apiKey,
            accessToken: (json["access_token"] as? String) ?? credentials.accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? credentials.refreshToken,
            idToken: (json["id_token"] as? String) ?? credentials.idToken,
            accountID: credentials.accountID,
            lastRefresh: Date()
        )
    }

    func tokenRefreshResponse(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?

        for attempt in 0 ..< Self.maxNetworkAttempts {
            do {
                let (data, response) = try await Self.liveSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ProviderError.network("Codex token 刷新失败：无 HTTP 响应")
                }

                let shouldRetry = isRetryableHTTPStatus(http.statusCode)
                guard shouldRetry, attempt < Self.maxNetworkAttempts - 1 else {
                    return (data, http)
                }
                lastError = QuotaHTTPError(
                    operation: "Codex token 刷新",
                    statusCode: http.statusCode,
                    isRetryable: true
                )
            } catch {
                if error is CancellationError {
                    throw error
                }
                if !isRetryableNetworkError(error) || attempt >= Self.maxNetworkAttempts - 1 {
                    throw error
                }
                lastError = error
            }

            try await Task.sleep(nanoseconds: retryDelayNanoseconds(for: attempt))
        }

        throw lastError ?? ProviderError.network("Codex token 刷新失败")
    }

    func writeCredentials(_ credentials: CodexCredentials, into root: [String: Any]) throws -> Data {
        var updatedRoot = root
        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        if let accessToken = credentials.accessToken {
            tokens["access_token"] = accessToken
        }
        if let refreshToken = credentials.refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountID = credentials.accountID {
            tokens["account_id"] = accountID
        }
        updatedRoot["tokens"] = tokens
        updatedRoot["last_refresh"] = ISO8601DateFormatter().string(from: credentials.lastRefresh ?? Date())
        return try JSONSerialization.data(withJSONObject: updatedRoot, options: [.prettyPrinted, .sortedKeys])
    }
}
