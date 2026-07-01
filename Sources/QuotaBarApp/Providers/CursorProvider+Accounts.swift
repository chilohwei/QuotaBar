import Foundation

extension CursorProvider {
    func importCurrentCredentials() async throws -> String {
        do {
            return try readLocalCursorCredentials()
        } catch {
            if let agentCredentials = try? readCursorAgentCredentials() {
                return agentCredentials
            }
            throw error
        }
    }

    func authenticateViaBrowser() async throws -> String {
        let initialSecret = try? readCursorAgentCredentials()
            ?? readLocalCursorCredentials()
        let initialCredentials = initialSecret.flatMap { try? parseCredentials($0) }

        if let agentURL = cursorAgentExecutableURL() {
            try await runCursorAgentLogin(agentURL: agentURL, timeout: 240)
            let latestSecret = try readCursorAgentCredentials()
            guard let latestSecret,
                  (try? parseCredentials(latestSecret)) != nil else {
                throw ProviderError.unsupported("Cursor Agent 登录完成，但未读取到本地凭据")
            }
            return latestSecret
        }

        try openCursorLoginPage()
        let timeout: TimeInterval = 240
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            if Task.isCancelled {
                throw CancellationError()
            }

            do {
                let latestSecret = try readLocalCursorCredentials()
                guard let latestCredentials = try? parseCredentials(latestSecret) else {
                    return latestSecret
                }

                if let initialCredentials {
                    if cursorCredentialsChanged(from: initialCredentials, to: latestCredentials) {
                        return latestSecret
                    }
                } else {
                    return latestSecret
                }
            } catch {
                lastError = error
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if let localized = (lastError as? LocalizedError)?.errorDescription,
           !localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProviderError.unsupported("未检测到 Cursor 登录完成，请在浏览器和 Cursor 中完成登录后重试（\(localized)）")
        }
        throw ProviderError.unsupported("未检测到新的 Cursor 登录凭据。请从 Cursor IDE 里触发登录，或安装 Cursor Agent 后重试")
    }

    func prepareAccount(_ account: Account, secret: String) async throws -> Account {
        var updated = account
        updated.settings.identityKey = accountIdentity(from: secret) ?? account.settings.identityKey
        return updated
    }

    func activate(account: Account, secret: String) async throws {
        _ = account
        let credentials = try parseCredentials(secret)
        try writeLocalCursorCredentials(credentials)
        let latest = try parseCredentials(try readLocalCursorCredentials())
        guard cursorCredentialsRepresentSameAccount(credentials, latest) else {
            throw ProviderError.network("Cursor 写入后读取到的账号不一致，请重启 Cursor 后重试")
        }
    }

    func fetchQuota(secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: Account(tool: .cursor, name: "Cursor"), secret: secret)
    }

    func fetchQuota(account: Account, secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: account, secret: secret, forceRefresh: false)
    }

    func fetchQuota(account: Account, secret: String, forceRefresh _: Bool) async throws -> QuotaSnapshot {
        let credentials = try parseCredentials(secret)
        try validateCursorCredentialsMatchAccount(credentials, account: account)
        let cacheKey = quotaCacheKey(credentials)

        do {
            let currentUsage = try await fetchCurrentPeriodUsage(accessToken: credentials.accessToken)
            let snapshot = try parseCurrentPeriodUsage(
                currentUsage,
                credentials: credentials
            )
            try? storeQuotaSnapshot(snapshot, cacheKey: cacheKey)
            return snapshot
        } catch {
            if isAuthenticationFailure(error) {
                throw error
            }

            if shouldUseCachedQuota(for: error),
               let cached = try? loadCachedQuotaSnapshot(cacheKey: cacheKey),
               Date().timeIntervalSince(cached.cachedAt) <= Self.fallbackQuotaCacheAge {
                return cached.snapshot.replacing(
                    source: "Cursor Cache",
                    note: mergedNote(cached.snapshot.note, fallback: QuotaNoteCatalog.cursorLiveUnavailableCache)
                )
            }

            let legacyUsage = try await fetchLegacyUsage(accessToken: credentials.accessToken)
            let snapshot = parseLegacyUsage(legacyUsage, credentials: credentials)
            try? storeQuotaSnapshot(snapshot, cacheKey: cacheKey)
            return snapshot
        }
    }

    func refreshSecretIfNeeded(_ secret: String) async throws -> String {
        try await refreshSecret(secret, force: false)
    }

    func refreshSecretAfterAuthenticationFailure(_ secret: String) async throws -> String? {
        let refreshed = try await refreshSecret(secret, force: true)
        return refreshed == secret ? nil : refreshed
    }

    func isAuthenticationFailure(_ error: Error) -> Bool {
        if let failure = error as? QuotaHTTPError {
            return failure.statusCode == 401
        }
        return false
    }

    func refreshSecret(_ secret: String, force: Bool) async throws -> String {
        var stored = try parseCredentials(secret)

        if force || shouldRefreshAccessToken(stored) {
            let refreshed = try await refreshAccessToken(credentials: stored)
            stored = try parseCredentials(refreshed)
        }

        guard let latest = try? readLocalCursorCredentials(),
              let latestCredentials = try? parseCredentials(latest),
              cursorCredentialsRepresentSameAccount(stored, latestCredentials) else {
            return encodeCredentials(stored)
        }

        if stored.accessToken != latestCredentials.accessToken {
            return latest
        }
        return encodeCredentials(stored)
    }

    func recoverSecret(for account: Account) async throws -> String? {
        guard let latest = try? readLocalCursorCredentials(),
              let latestCredentials = try? parseCredentials(latest) else {
            return nil
        }

        guard let expectedIdentity = account.settings.identityKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedIdentity.isEmpty else {
            if let accountEmail = emailAddress(in: account.name),
               cursorCredentialIdentityCandidates(latestCredentials).contains(normalizeIdentity("cursor:email:\(accountEmail)"))
                || cursorCredentialIdentityCandidates(latestCredentials).contains(normalizeIdentity("cursor:\(accountEmail)")) {
                return encodeCredentials(latestCredentials)
            }
            return nil
        }

        return cursorCredentialIdentityCandidates(latestCredentials).contains(normalizeIdentity(expectedIdentity))
            ? encodeCredentials(latestCredentials)
            : nil
    }

    func accountIdentity(from secret: String) -> String? {
        accountIdentityAliases(from: secret).first
    }

    func accountIdentityAliases(from secret: String) -> [String] {
        guard let credentials = try? parseCredentials(secret) else { return [] }
        var aliases: [String] = []
        if let subject = jwtStringClaim(credentials.accessToken, claim: "sub")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subject.isEmpty {
            aliases.append("cursor:sub:\(subject.lowercased())")
            aliases.append("cursor:\(subject.lowercased())")
        }
        if let email = cursorAccountEmail(from: credentials)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !email.isEmpty {
            aliases.append("cursor:email:\(email)")
            aliases.append("cursor:\(email)")
        }
        if let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshToken.isEmpty {
            aliases.append("cursor:refresh:\(refreshToken.suffix(16))")
            aliases.append("cursor:\(refreshToken.suffix(16))")
        }
        aliases.append("cursor:token:\(credentials.accessToken.suffix(16))")
        aliases.append("cursor:\(credentials.accessToken.suffix(16))")
        return uniqueIdentityAliases(aliases)
    }

    func suggestAccountName(from secret: String) -> String? {
        guard let credentials = try? parseCredentials(secret) else { return nil }
        if let email = cursorAccountEmail(from: credentials)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email.lowercased()
        }
        return "Cursor"
    }

}
