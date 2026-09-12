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
        try await authenticateViaBrowser(allowExistingCredentials: true)
    }

    func authenticateViaBrowser(allowExistingCredentials: Bool) async throws -> String {
        let initialSecret = await currentImportedCursorSecret()
        let initialCredentials = initialSecret.flatMap { try? parseCredentials($0) }

        if let existingSecret = initialSecret,
           cursorImportedSecret(
               existingSecret,
               isAcceptableComparedTo: initialCredentials,
               allowExistingCredentials: allowExistingCredentials
           ) {
            return existingSecret
        }

        let session = makeCursorOAuthLoginSession()
        try openCursorOAuthLoginPage(session: session)
        let timeout: TimeInterval = 240
        await MainActor.run { [self] in
            LoginFlowProgress.shared.begin(method: .browser, timeout: timeout) {
                try? openCursorOAuthLoginPage(session: session)
            }
        }
        return try await waitForCursorOAuthLogin(
            session: session,
            timeout: timeout,
            initialCredentials: initialCredentials,
            allowExistingCredentials: allowExistingCredentials
        )
    }

    func currentImportedCursorSecret() async -> String? {
        guard let secret = try? await importCurrentCredentials(),
              !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? parseCredentials(secret)) != nil else {
            return nil
        }
        return secret
    }

    func cursorImportedSecret(
        _ secret: String,
        isAcceptableComparedTo initialCredentials: CursorCredentials?,
        allowExistingCredentials: Bool
    ) -> Bool {
        guard let latestCredentials = try? parseCredentials(secret) else {
            return false
        }
        guard !allowExistingCredentials, let initialCredentials else {
            return true
        }
        return !cursorCredentialsRepresentSameAccount(initialCredentials, latestCredentials)
    }

    func waitForCursorOAuthLogin(
        session: CursorOAuthLoginSession,
        timeout: TimeInterval,
        initialCredentials: CursorCredentials?,
        allowExistingCredentials: Bool
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            try Task.checkCancellation()

            do {
                if var credentials = try await pollCursorOAuthCredentials(session: session) {
                    if cursorAccountEmail(from: credentials) == nil,
                       let email = await fetchCursorAccountEmail(accessToken: credentials.accessToken) {
                        credentials = CursorCredentials(
                            accessToken: credentials.accessToken,
                            refreshToken: credentials.refreshToken,
                            email: email,
                            membershipType: credentials.membershipType,
                            subscriptionStatus: credentials.subscriptionStatus,
                            subscriptionPeriodEnd: credentials.subscriptionPeriodEnd,
                            stateDatabasePath: credentials.stateDatabasePath,
                            source: credentials.source
                        )
                    }
                    return encodeCredentials(credentials)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }

            // The user may finish signing in from the Cursor IDE instead of the browser flow.
            if let latestSecret = await currentImportedCursorSecret(),
               cursorImportedSecret(
                   latestSecret,
                   isAcceptableComparedTo: initialCredentials,
                   allowExistingCredentials: allowExistingCredentials
               ) {
                return latestSecret
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        if let localized = (lastError as? LocalizedError)?.errorDescription,
           !localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProviderError.loginIncomplete(tool: .cursor, message: "未检测到 Cursor 登录完成，请在浏览器完成授权后重试（\(localized)）")
        }
        throw ProviderError.loginIncomplete(tool: .cursor, message: "Cursor 浏览器登录超时，请在浏览器完成授权后重试")
    }

    func prepareAccount(_ account: Account, secret: String) async throws -> Account {
        var updated = account
        let profilePath = account.settings.cursorProfilePath ?? AppPaths.managedCursorProfilePath(accountID: account.id)
        updated.settings.cursorProfilePath = profilePath
        updated.settings.identityKey = accountIdentity(from: secret) ?? account.settings.identityKey

        let encoded = encodeCredentials(try credentialsForInstalledTool(from: secret))
        try writeManagedCredentialsSnapshot(encoded, for: updated)
        return updated
    }

    func activate(account: Account, secret: String) async throws {
        let credentials = try credentialsForInstalledTool(from: secret)
        try writeLocalCursorCredentials(credentials)

        let encoded = encodeCredentials(credentials)
        try writeManagedCredentialsSnapshot(encoded, for: account)
    }

    func fetchQuota(secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: Account(tool: .cursor, name: "Cursor"), secret: secret)
    }

    func fetchQuota(account: Account, secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: account, secret: secret, intent: .background)
    }

    func fetchQuota(account: Account, secret: String, intent: RefreshIntent) async throws -> QuotaSnapshot {
        _ = intent
        let credentials = try parseCredentials(secret)
        try validateCursorCredentialsMatchAccount(credentials, account: account)
        let cacheKey = quotaCacheKey(credentials)

        do {
            let currentUsage = try await fetchCurrentPeriodUsage(accessToken: credentials.accessToken)
            let planInfo = try? await fetchPlanInfo(accessToken: credentials.accessToken)
            let resolvedPlanName = resolvedPlanName(from: planInfo, credentials: credentials)

            if shouldUseUsageSummaryFallback(currentUsage, planName: resolvedPlanName) {
                if let summary = try await fetchUsageSummary(accessToken: credentials.accessToken) {
                    let requestUsage = try? await fetchRequestBasedUsage(accessToken: credentials.accessToken)
                    let snapshot = try parseUsageSummaryFallback(
                        summary: summary,
                        requestUsage: requestUsage,
                        credentials: credentials,
                        planName: resolvedPlanName
                    )
                    try? storeQuotaSnapshot(snapshot, cacheKey: cacheKey)
                    return snapshot
                }
            }

            let snapshot = try parseCurrentPeriodUsage(
                currentUsage,
                credentials: credentials,
                planNameOverride: resolvedPlanName
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
                // Same rule as the other providers: drop windows whose reset has
                // passed, and skip the cache entirely if nothing live remains.
                let pruned = cached.snapshot.removingExpiredWindows()
                if !pruned.orderedMetrics.isEmpty {
                    return pruned.replacing(
                        source: "Cursor Cache",
                        note: mergedNote(pruned.note, fallback: QuotaNoteCatalog.cursorLiveUnavailableCache),
                        availabilityStatus: .serviceUnavailable
                    )
                }
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
            return failure.statusCode == 401 || failure.statusCode == 403
        }
        if case .tokenExpired = error as? ProviderError {
            return true
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
        let managedCandidates = [
            account.settings.cursorProfilePath,
            AppPaths.managedCursorProfilePath(accountID: account.id)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        for profilePath in Set(managedCandidates) {
            let credentialsPath = "\(profilePath)/credentials.json"
            guard fileService.fileExists(at: credentialsPath) else { continue }
            let secret = try fileService.readText(at: credentialsPath)
            if recoveredSecretMatches(secret, account: account) {
                return secret
            }
        }

        if account.settings.identityKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return nil
        }

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
