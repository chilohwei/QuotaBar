import Foundation

extension CodexProvider {
    func fetchQuota(secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: Account(tool: .codex, name: "Codex"), secret: secret)
    }

    func fetchQuota(account: Account, secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: account, secret: secret, forceRefresh: false)
    }

    func fetchQuota(account: Account, secret: String, forceRefresh: Bool) async throws -> QuotaSnapshot {
        try await fetchQuotaCore(account: account, secret: secret, forceRefresh: forceRefresh)
    }

    private func fetchQuotaCore(account: Account, secret: String, forceRefresh: Bool) async throws -> QuotaSnapshot {
        guard let data = secret.data(using: .utf8) else {
            throw ProviderError.credentialParsingFailed(tool: .codex)
        }

        let credentials = try parseCredentials(data: data)
        let identity = extractIdentity(fromIDToken: credentials.idToken)
        let registryKey = normalizedRegistryKey(account.settings.codexRegistryKey)
        let resolvedAccountKey = identity.accountKey ?? registryKey
        let registryMeta = resolvedAccountKey.flatMap(loadRegistryAccountMetadata)
        let resolvedAccountID = identity.chatGPTAccountID
            ?? credentials.accountID
            ?? registryMeta?.chatGPTAccountID
        let resolvedFallbackIdentifier = identity.email ?? registryMeta?.email
        var subscriptionMeta = loadSubscriptionCacheMetadata(
            accountKey: resolvedAccountKey,
            accountID: resolvedAccountID,
            email: resolvedFallbackIdentifier
        )

        if let accessToken = credentials.accessToken, !accessToken.isEmpty {
            if let refreshedSubscription = await fetchSubscriptionIfNeeded(
                accessToken: accessToken,
                accountID: resolvedAccountID,
                accountKey: resolvedAccountKey,
                email: resolvedFallbackIdentifier,
                existing: subscriptionMeta
            ) {
                subscriptionMeta = refreshedSubscription
            }

            let fallbackPlanName = normalizedPlanName(
                identity.plan ?? registryMeta?.planName ?? subscriptionMeta?.planName,
                cycle: identity.cycle ?? registryMeta?.billingCycle ?? subscriptionMeta?.billingCycle
            )

            do {
                return try await fetchOAuthUsage(
                    accessToken: accessToken,
                    accountID: resolvedAccountID,
                    accountKey: resolvedAccountKey,
                    codexHomePath: nil,
                    fallbackAccountIdentifier: resolvedFallbackIdentifier,
                    fallbackPlanName: fallbackPlanName,
                    fallbackAccountValidUntil: identity.accountValidUntil ?? subscriptionMeta?.accountValidUntil,
                    fallbackSubscriptionWillRenew: identity.subscriptionWillRenew ?? subscriptionMeta?.subscriptionWillRenew,
                    fallbackSubscriptionStatus: identity.subscriptionStatus ?? subscriptionMeta?.subscriptionStatus
                )
            } catch {
                if let apiKey = credentials.apiKey, !apiKey.isEmpty {
                    return try await fetchCreditGrants(apiKey: apiKey, note: QuotaNoteCatalog.codexOAuthFellBackToApiKey)
                }
                throw error
            }
        }

        if let apiKey = credentials.apiKey, !apiKey.isEmpty {
            return try await fetchCreditGrants(apiKey: apiKey, note: nil)
        }

        throw ProviderError.noUsableCredential(tool: .codex)
    }

    func fetchOAuthUsage(
        accessToken: String,
        accountID: String?,
        accountKey: String?,
        codexHomePath: String?,
        fallbackAccountIdentifier: String?,
        fallbackPlanName: String?,
        fallbackAccountValidUntil: Date?,
        fallbackSubscriptionWillRenew: Bool?,
        fallbackSubscriptionStatus: String?
    ) async throws -> QuotaSnapshot {
        let cacheKey = quotaCacheKey(
            accountKey: accountKey,
            accountID: accountID,
            fallbackAccountIdentifier: fallbackAccountIdentifier
        )

        let url = resolveUsageURL(codexHomePath: codexHomePath)
        let request = makeOAuthUsageRequest(url: url, accessToken: accessToken, accountID: accountID)

        let data: Data
        do {
            data = try await dataWithOfficialFallback(
                primaryRequest: request,
                primaryURL: url,
                accessToken: accessToken,
                accountID: accountID
            )
        } catch {
            if shouldUseCachedQuota(for: error),
               let cacheKey,
               let cached = try? loadCachedQuotaSnapshot(cacheKey: cacheKey),
               Date().timeIntervalSince(cached.cachedAt) <= Self.fallbackQuotaCacheAge {
                let note = mergedNote(
                    cached.snapshot.note,
                    fallback: "实时接口暂不可用，正在显示缓存数据"
                )
                return cached.snapshot.replacing(source: "Codex OAuth Cache", note: note)
            }
            throw error
        }

        let payload = try JSONSerialization.jsonObject(with: data)
        try validateCodexUsageIdentity(
            in: payload,
            expectedAccountKey: accountKey,
            expectedEmail: fallbackAccountIdentifier
        )
        let resolvedPlanName = normalizedPlanName(
            extractPlanName(from: payload) ?? fallbackPlanName,
            cycle: extractBillingCycle(from: payload) ?? fallbackPlanName
        )
        let directSnapshot = parseCodexRateLimitPayload(
            payload,
            fallbackAccountIdentifier: fallbackAccountIdentifier,
            fallbackPlanName: resolvedPlanName,
            fallbackAccountValidUntil: paidAccountValidUntil(resolvedPlanName, fallbackAccountValidUntil),
            fallbackSubscriptionWillRenew: fallbackSubscriptionWillRenew,
            fallbackSubscriptionStatus: fallbackSubscriptionStatus
        )
        if let directSnapshot {
            if let cacheKey {
                try? storeQuotaSnapshot(directSnapshot, cacheKey: cacheKey)
            }
            try? updateStoredUsage(
                directSnapshot,
                accountKey: accountKey,
                accountID: accountID,
                email: fallbackAccountIdentifier
            )
            try? storeSubscriptionCache(
                directSnapshot,
                accountKey: accountKey,
                accountID: accountID,
                email: fallbackAccountIdentifier
            )
            return directSnapshot
        }

        let windows = UsageWindowExtractor.extract(from: payload)
        let sortedWindows = windows.sorted { $0.limit > $1.limit }

        let snapshot = QuotaSnapshot(
            source: "Codex OAuth",
            accountIdentifier: fallbackAccountIdentifier,
            planName: resolvedPlanName,
            primary: sortedWindows.first,
            secondary: sortedWindows.dropFirst().first,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: .init(),
            periodEnd: nil,
            accountValidUntil: paidAccountValidUntil(resolvedPlanName, fallbackAccountValidUntil),
            subscriptionWillRenew: fallbackSubscriptionWillRenew,
            subscriptionStatus: fallbackSubscriptionStatus,
            note: windows.isEmpty ? QuotaNoteCatalog.codexNoStandardFields : nil
        )
        if let cacheKey {
            try? storeQuotaSnapshot(snapshot, cacheKey: cacheKey)
        }
        try? updateStoredUsage(
            snapshot,
            accountKey: accountKey,
            accountID: accountID,
            email: fallbackAccountIdentifier
        )
        try? storeSubscriptionCache(
            snapshot,
            accountKey: accountKey,
            accountID: accountID,
            email: fallbackAccountIdentifier
        )
        return snapshot
    }

    func makeOAuthUsageRequest(url: URL, accessToken: String, accountID: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(chatGPTUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    func fetchSubscriptionIfNeeded(
        accessToken: String,
        accountID: String?,
        accountKey: String?,
        email: String?,
        existing: SubscriptionCacheMetadata?
    ) async -> SubscriptionCacheMetadata? {
        guard let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty else {
            return existing
        }

        do {
            let url = resolveSubscriptionURL(codexHomePath: nil)
            let request = makeOAuthSubscriptionRequest(url: url, accessToken: accessToken, accountID: accountID)
            let data = try await dataWithOfficialSubscriptionFallback(
                primaryRequest: request,
                primaryURL: url,
                accessToken: accessToken,
                accountID: accountID
            )
            let payload = try JSONSerialization.jsonObject(with: data)
            guard let metadata = parseSubscriptionMetadata(from: payload) else {
                return existing
            }
            try? storeSubscriptionCache(metadata, accountKey: accountKey, accountID: accountID, email: email)
            return metadata
        } catch {
            return existing
        }
    }

    func makeOAuthSubscriptionRequest(url: URL, accessToken: String, accountID: String) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "account_id", value: accountID)]
        var request = URLRequest(url: components?.url ?? url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(chatGPTUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        return request
    }

    func dataWithOfficialSubscriptionFallback(
        primaryRequest: URLRequest,
        primaryURL: URL,
        accessToken: String,
        accountID: String
    ) async throws -> Data {
        do {
            return try await dataWithRetry(for: primaryRequest, operation: "Codex 订阅查询")
        } catch {
            guard shouldRetryAgainstOfficialUsageURL(for: error, primaryURL: primaryURL) else {
                throw error
            }
            let fallbackRequest = makeOAuthSubscriptionRequest(
                url: URL(string: "https://chatgpt.com/backend-api/subscriptions")!,
                accessToken: accessToken,
                accountID: accountID
            )
            return try await dataWithRetry(for: fallbackRequest, operation: "Codex 订阅查询(官方域名兜底)")
        }
    }

    func parseSubscriptionMetadata(from payload: Any) -> SubscriptionCacheMetadata? {
        let planName = extractPlanName(from: payload)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let billingCycle = extractBillingCycle(from: payload)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscriptionStatus = extractSubscriptionStatus(from: payload)
        let metadata = SubscriptionCacheMetadata(
            planName: (planName?.isEmpty == false) ? planName : nil,
            billingCycle: (billingCycle?.isEmpty == false) ? billingCycle : nil,
            accountValidUntil: extractSubscriptionActiveUntil(from: payload),
            subscriptionWillRenew: extractSubscriptionWillRenew(from: payload, subscriptionStatus: subscriptionStatus),
            subscriptionStatus: subscriptionStatus,
            fetchedAt: Date()
        )

        let hasValue = metadata.planName != nil
            || metadata.billingCycle != nil
            || metadata.accountValidUntil != nil
            || metadata.subscriptionWillRenew != nil
            || metadata.subscriptionStatus != nil
        return hasValue ? metadata : nil
    }

    func dataWithOfficialFallback(
        primaryRequest: URLRequest,
        primaryURL: URL,
        accessToken: String,
        accountID: String?
    ) async throws -> Data {
        do {
            return try await dataWithRetry(for: primaryRequest, operation: "Codex OAuth 查询")
        } catch {
            guard shouldRetryAgainstOfficialUsageURL(for: error, primaryURL: primaryURL) else {
                throw error
            }
            let fallbackRequest = makeOAuthUsageRequest(
                url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                accessToken: accessToken,
                accountID: accountID
            )
            return try await dataWithRetry(for: fallbackRequest, operation: "Codex OAuth 查询(官方域名兜底)")
        }
    }

    func shouldRetryAgainstOfficialUsageURL(for error: Error, primaryURL: URL) -> Bool {
        guard isRetryableNetworkError(error) else { return false }
        let host = primaryURL.host?.lowercased() ?? ""
        return host != "chatgpt.com" && host != "chat.openai.com"
    }

    func dataWithRetry(for request: URLRequest, operation: String) async throws -> Data {
        try await Self.httpClient.data(for: request, operation: operation)
    }

    func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 409 || statusCode == 425 || statusCode == 429 || (500 ... 599).contains(statusCode)
    }

    func isRetryableNetworkError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        return QuotaHTTPClient.isRetryableNetworkError(error)
    }

    func shouldTreatAsTransientNetworkError(_ error: Error) -> Bool {
        isRetryableNetworkError(error)
    }

    func shouldUseCachedQuota(for error: Error) -> Bool {
        isRetryableNetworkError(error)
    }

    func retryDelayNanoseconds(for attempt: Int) -> UInt64 {
        let seconds = [0.35, 0.9, 1.8][min(attempt, 2)]
        return UInt64(seconds * 1_000_000_000)
    }
}
