import Foundation

struct CursorProvider: Provider {
    let tool: ToolKind = .cursor
    private let fileService = FileService()
    private let apiBaseURL = URL(string: "https://api2.cursor.sh")!
    private static let cycleBoundaryDateKeys: Set<String> = [
        "billingCycleEnd",
        "billing_cycle_end",
        "billingCycleEndAt",
        "billing_cycle_end_at",
        "currentPeriodEnd",
        "current_period_end",
        "currentPeriodEndAt",
        "current_period_end_at",
        "subscriptionCurrentPeriodEnd",
        "subscription_current_period_end",
        "subscriptionPeriodEnd",
        "subscription_period_end",
        "stripeCurrentPeriodEnd",
        "stripe_current_period_end",
        "periodEnd",
        "period_end",
        "cycleEnd",
        "cycle_end",
        "subscriptionExpiresAt",
        "subscription_expires_at",
        "nextBillingDate",
        "next_billing_date",
        "nextBillingAt",
        "next_billing_at",
        "renewalDate",
        "renewal_date",
        "resetAt",
        "reset_at",
        "resetAtMs",
        "reset_at_ms",
        "nextResetAt",
        "next_reset_at",
        "nextResetAtMs",
        "next_reset_at_ms"
    ]

    private static let freshQuotaCacheAge: TimeInterval = 60
    private static let fallbackQuotaCacheAge: TimeInterval = 24 * 60 * 60
    private static let maxNetworkAttempts = 3

    private struct CursorCredentials: Codable {
        let accessToken: String
        let refreshToken: String?
        let email: String?
        let membershipType: String?
        let subscriptionStatus: String?
        let subscriptionPeriodEnd: Date?
        let stateDatabasePath: String?
        let source: String?
    }

    private struct CursorTokenRefreshResponse: Decodable {
        let accessToken: String?
        let idToken: String?
        let shouldLogout: Bool?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case idToken = "id_token"
            case shouldLogout
        }
    }

    private struct CachedQuotaSnapshot: Codable {
        let schemaVersion: Int
        let cachedAt: Date
        let snapshot: QuotaSnapshot
    }

    private struct HTTPRequestFailure: LocalizedError {
        let operation: String
        let statusCode: Int
        let isRetryable: Bool

        var errorDescription: String? {
            "\(operation)失败，HTTP \(statusCode)"
        }
    }

    private struct CursorStateSnapshot {
        let directoryPath: String
        let databasePath: String
    }

    private struct CursorStateCandidate {
        let path: String
        let modifiedAt: Date
    }

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

    func fetchQuota(account: Account, secret: String, forceRefresh: Bool) async throws -> QuotaSnapshot {
        let credentials = try parseCredentials(secret)
        try validateCursorCredentialsMatchAccount(credentials, account: account)
        let cacheKey = quotaCacheKey(credentials)

        if !forceRefresh,
           let cached = try? loadCachedQuotaSnapshot(cacheKey: cacheKey),
           Date().timeIntervalSince(cached.cachedAt) <= Self.freshQuotaCacheAge {
            return cached.snapshot.replacing(source: "Cursor Cache")
        }

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
                    note: mergedNote(cached.snapshot.note, fallback: "实时接口暂不可用，正在显示缓存数据")
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
        if let failure = error as? HTTPRequestFailure {
            return failure.statusCode == 401
        }
        return false
    }

    private func refreshSecret(_ secret: String, force: Bool) async throws -> String {
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

    private func readLocalCursorCredentials() throws -> String {
        let candidates = cursorStateDatabaseCandidates()
            .compactMap(cursorStateCandidateIfExists)
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })

        guard !candidates.isEmpty else {
            throw ProviderError.unsupported("未找到 Cursor 登录状态，请先打开 Cursor 并登录")
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                return try readLocalCursorCredentials(statePath: candidate.path)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ProviderError.unsupported("未找到 Cursor 登录 token，请先在 Cursor 中登录")
    }

    private func readLocalCursorCredentials(statePath: String) throws -> String {
        guard fileService.fileExists(at: statePath) else {
            throw ProviderError.unsupported("未找到 Cursor 登录状态，请先打开 Cursor 并登录")
        }

        let values = try readCursorStateValues(
            keys: [
                "cursorAuth/accessToken",
                "cursorAuth/refreshToken",
                "cursorAuth/cachedEmail",
                "cursorAuth/stripeMembershipType",
                "cursorAuth/stripeSubscriptionStatus",
                "cursorAuth/stripeCurrentPeriodEnd",
                "cursorAuth/subscriptionCurrentPeriodEnd"
            ],
            statePath: statePath
        )
        let accessToken = values["cursorAuth/accessToken"]
        guard let accessToken, !accessToken.isEmpty else {
            throw ProviderError.unsupported("未找到 Cursor 登录 token，请先在 Cursor 中登录")
        }

        let credentials = CursorCredentials(
            accessToken: accessToken,
            refreshToken: values["cursorAuth/refreshToken"],
            email: values["cursorAuth/cachedEmail"],
            membershipType: values["cursorAuth/stripeMembershipType"],
            subscriptionStatus: values["cursorAuth/stripeSubscriptionStatus"],
            subscriptionPeriodEnd: parseDate(values["cursorAuth/stripeCurrentPeriodEnd"] ?? values["cursorAuth/subscriptionCurrentPeriodEnd"] ?? ""),
            stateDatabasePath: fileService.expand(path: statePath),
            source: "cursorDesktopState"
        )
        return encodeCredentials(credentials)
    }

    private func writeLocalCursorCredentials(_ credentials: CursorCredentials) throws {
        let preferredPath = credentials.stateDatabasePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = cursorStateDatabaseCandidates()
            .compactMap(cursorStateCandidateIfExists)
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })

        let targetPath: String?
        if let preferredPath,
           fileService.fileExists(at: preferredPath) {
            targetPath = preferredPath
        } else {
            targetPath = candidates.first?.path
        }

        guard let targetPath else {
            throw ProviderError.unsupported("未找到 Cursor 登录状态，请先打开 Cursor 并登录一次")
        }

        let email = cursorAccountEmail(from: credentials)
        var upserts: [String: String] = [
            "cursorAuth/accessToken": credentials.accessToken
        ]
        if let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshToken.isEmpty {
            upserts["cursorAuth/refreshToken"] = refreshToken
        }
        if let email {
            upserts["cursorAuth/cachedEmail"] = email
        }
        if let membershipType = credentials.membershipType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !membershipType.isEmpty {
            upserts["cursorAuth/stripeMembershipType"] = membershipType
        }
        if let subscriptionStatus = credentials.subscriptionStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subscriptionStatus.isEmpty {
            upserts["cursorAuth/stripeSubscriptionStatus"] = subscriptionStatus
        }
        if let subscriptionPeriodEnd = credentials.subscriptionPeriodEnd {
            upserts["cursorAuth/stripeCurrentPeriodEnd"] = ISO8601DateFormatter().string(from: subscriptionPeriodEnd)
            upserts["cursorAuth/subscriptionCurrentPeriodEnd"] = ISO8601DateFormatter().string(from: subscriptionPeriodEnd)
        }

        let deleteKeys = [
            credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ? "cursorAuth/refreshToken" : nil,
            email == nil ? "cursorAuth/cachedEmail" : nil,
            credentials.membershipType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ? "cursorAuth/stripeMembershipType" : nil,
            credentials.subscriptionStatus?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ? "cursorAuth/stripeSubscriptionStatus" : nil,
            credentials.subscriptionPeriodEnd == nil ? "cursorAuth/stripeCurrentPeriodEnd" : nil,
            credentials.subscriptionPeriodEnd == nil ? "cursorAuth/subscriptionCurrentPeriodEnd" : nil
        ].compactMap { $0 }

        try updateCursorStateDatabase(
            statePath: targetPath,
            upserts: upserts,
            deleteKeys: deleteKeys
        )
    }

    private func readCursorAgentCredentials() throws -> String? {
        guard let accessToken = try readKeychainPassword(service: "cursor-access-token"),
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let credentials = CursorCredentials(
            accessToken: accessToken,
            refreshToken: try readKeychainPassword(service: "cursor-refresh-token"),
            email: cursorAgentEmail(),
            membershipType: nil,
            subscriptionStatus: nil,
            subscriptionPeriodEnd: nil,
            stateDatabasePath: nil,
            source: "cursorAgentKeychain"
        )
        return encodeCredentials(credentials)
    }

    private func cursorStateDatabaseCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Cursor - Insiders/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Cursor Nightly/User/globalStorage/state.vscdb"
        ]
    }

    private func cursorStateCandidateIfExists(path: String) -> CursorStateCandidate? {
        let expanded = fileService.expand(path: path)
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: expanded)
        let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
        return CursorStateCandidate(path: path, modifiedAt: modifiedAt)
    }

    private func cursorAccountEmail(from credentials: CursorCredentials) -> String? {
        let claimKeys = [
            "email",
            "https://cursor.sh/email",
            "https://cursor.com/email"
        ]
        for key in claimKeys {
            if let email = jwtStringClaim(credentials.accessToken, claim: key),
               let normalized = emailAddress(in: email) {
                return normalized
            }
        }
        if let email = credentials.email,
           let normalized = emailAddress(in: email) {
            return normalized
        }
        return nil
    }

    private func cursorCredentialIdentityCandidates(_ credentials: CursorCredentials) -> Set<String> {
        var candidates = Set<String>()
        if let subject = jwtStringClaim(credentials.accessToken, claim: "sub")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subject.isEmpty {
            candidates.insert(normalizeIdentity("cursor:sub:\(subject.lowercased())"))
            candidates.insert(normalizeIdentity("cursor:\(subject)"))
        }
        if let email = cursorAccountEmail(from: credentials) {
            candidates.insert(normalizeIdentity("cursor:email:\(email)"))
            candidates.insert(normalizeIdentity("cursor:\(email)"))
        }
        if let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshToken.isEmpty {
            candidates.insert(normalizeIdentity("cursor:refresh:\(refreshToken.suffix(16))"))
            candidates.insert(normalizeIdentity("cursor:\(refreshToken.suffix(16))"))
        }
        candidates.insert(normalizeIdentity("cursor:token:\(credentials.accessToken.suffix(16))"))
        candidates.insert(normalizeIdentity("cursor:\(credentials.accessToken.suffix(16))"))
        return candidates
    }

    private func uniqueIdentityAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        return aliases.filter { alias in
            seen.insert(normalizeIdentity(alias)).inserted
        }
    }

    private func validateCursorCredentialsMatchAccount(_ credentials: CursorCredentials, account: Account) throws {
        guard let expectedIdentity = account.settings.identityKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedIdentity.isEmpty else {
            return
        }

        guard cursorCredentialIdentityCandidates(credentials).contains(normalizeIdentity(expectedIdentity)) else {
            throw ProviderError.network("Cursor 凭据与当前账号不一致，请重新登录或重新添加该账号")
        }
    }

    private func emailAddress(in text: String) -> String? {
        let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange]).lowercased()
    }

    private func openCursorLoginPage() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["https://cursor.com/login"]
        try process.run()
    }

    private func cursorAgentExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/cursor-agent",
            "\(home)/.local/bin/agent",
            "/opt/homebrew/bin/cursor-agent",
            "/opt/homebrew/bin/agent",
            "/usr/local/bin/cursor-agent",
            "/usr/local/bin/agent"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func runCursorAgentLogin(agentURL: URL, timeout: TimeInterval) async throws {
        let process = Process()
        process.executableURL = agentURL
        process.arguments = ["login"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)

        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                throw ProviderError.unsupported("Cursor Agent 登录超时，请完成浏览器登录后重试")
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        guard process.terminationStatus == 0 else {
            let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let outputText = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = [errorText, outputText]
                .compactMap { text in
                    guard let text, !text.isEmpty else { return nil }
                    return text
                }
                .joined(separator: "\n")
            throw ProviderError.unsupported(message.isEmpty ? "Cursor Agent 登录失败" : "Cursor Agent 登录失败：\(message)")
        }
    }

    private func readKeychainPassword(service: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cursorAgentEmail() -> String? {
        guard let agentURL = cursorAgentExecutableURL() else { return nil }
        let process = Process()
        process.executableURL = agentURL
        process.arguments = ["status"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }

        let pattern = #"(?i)logged in as\s+([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[range]).lowercased()
    }

    private func readCursorStateValues(keys: [String], statePath: String) throws -> [String: String] {
        let immutableURI = sqliteImmutableURI(for: statePath)
        if let directValues = try? queryCursorStateDatabase(
            databasePath: immutableURI,
            keys: keys
        ), !directValues.isEmpty {
            return directValues
        }

        let snapshot = try makeCursorStateSnapshot(statePath: statePath)
        defer {
            try? fileService.removeItemIfExists(at: snapshot.directoryPath)
        }

        return try queryCursorStateDatabase(databasePath: snapshot.databasePath, keys: keys)
    }

    private func queryCursorStateDatabase(databasePath: String, keys: [String]) throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let quotedKeys = keys
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ",")
        process.arguments = [
            "-readonly",
            "-batch",
            "-noheader",
            "-separator",
            "\t",
            databasePath,
            "SELECT key, value FROM ItemTable WHERE key IN (\(quotedKeys));"
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.network("读取 Cursor 登录状态失败\(message.map { "：\($0)" } ?? "")")
        }

        guard let output, !output.isEmpty else { return [:] }
        return output
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { result, line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return }
                result[String(parts[0])] = decodeCursorStateValue(String(parts[1]))
            }
    }

    private func updateCursorStateDatabase(
        statePath: String,
        upserts: [String: String],
        deleteKeys: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-batch",
            fileService.expand(path: statePath)
        ]

        let script = cursorStateUpdateSQL(upserts: upserts, deleteKeys: deleteKeys)
        let inputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardError = errorPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(Data(script.utf8))
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.network("写入 Cursor 登录状态失败\(message.map { "：\($0)" } ?? "")")
        }
    }

    private func cursorStateUpdateSQL(upserts: [String: String], deleteKeys: [String]) -> String {
        var statements = [
            "PRAGMA busy_timeout = 5000;",
            "BEGIN IMMEDIATE;"
        ]

        for (key, value) in upserts.sorted(by: { $0.key < $1.key }) {
            statements.append(
                "INSERT OR REPLACE INTO ItemTable(key, value) VALUES (\(sqlStringLiteral(key)), \(sqlStringLiteral(value)));"
            )
        }

        for key in deleteKeys.sorted() {
            guard upserts[key] == nil else { continue }
            statements.append("DELETE FROM ItemTable WHERE key = \(sqlStringLiteral(key));")
        }

        statements.append("COMMIT;")
        return statements.joined(separator: "\n") + "\n"
    }

    private func sqlStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func sqliteImmutableURI(for path: String) -> String {
        URL(fileURLWithPath: fileService.expand(path: path)).absoluteString + "?mode=ro&immutable=1"
    }

    private func makeCursorStateSnapshot(statePath: String) throws -> CursorStateSnapshot {
        let expanded = fileService.expand(path: statePath)
        let sourceURL = URL(fileURLWithPath: expanded)
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-cursor-state-\(UUID().uuidString)", isDirectory: true)
        let snapshotDatabase = snapshotDirectory.appendingPathComponent(sourceURL.lastPathComponent)

        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: snapshotDatabase)
            try copyIfExists(from: URL(fileURLWithPath: expanded + "-wal"), to: URL(fileURLWithPath: snapshotDatabase.path + "-wal"))
            try copyIfExists(from: URL(fileURLWithPath: expanded + "-shm"), to: URL(fileURLWithPath: snapshotDatabase.path + "-shm"))
        } catch {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw ProviderError.network("读取 Cursor 登录状态失败：无法创建数据库快照（\(error.localizedDescription)）")
        }

        return CursorStateSnapshot(
            directoryPath: snapshotDirectory.path,
            databasePath: snapshotDatabase.path
        )
    }

    private func copyIfExists(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func decodeCursorStateValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return decoded
    }

    private func parseCredentials(_ secret: String) throws -> CursorCredentials {
        guard let data = secret.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
        }
        return try JSONDecoder().decode(CursorCredentials.self, from: data)
    }

    private func cursorCredentialsChanged(from old: CursorCredentials, to new: CursorCredentials) -> Bool {
        if old.accessToken != new.accessToken {
            return true
        }
        let oldEmail = old.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let newEmail = new.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return !oldEmail.isEmpty && !newEmail.isEmpty && oldEmail != newEmail
    }

    private func cursorCredentialsRepresentSameAccount(_ lhs: CursorCredentials, _ rhs: CursorCredentials) -> Bool {
        let lhsEmail = cursorAccountEmail(from: lhs) ?? ""
        let rhsEmail = cursorAccountEmail(from: rhs) ?? ""
        if !lhsEmail.isEmpty || !rhsEmail.isEmpty {
            return !lhsEmail.isEmpty && lhsEmail == rhsEmail
        }

        let lhsSubject = jwtStringClaim(lhs.accessToken, claim: "sub")
        let rhsSubject = jwtStringClaim(rhs.accessToken, claim: "sub")
        if let lhsSubject, let rhsSubject {
            return lhsSubject == rhsSubject
        }

        return lhs.accessToken == rhs.accessToken
    }

    private func normalizeIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func encodeCredentials(_ credentials: CursorCredentials) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(credentials) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func shouldRefreshAccessToken(_ credentials: CursorCredentials) -> Bool {
        guard let refreshToken = credentials.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expiresAt = jwtExpirationDate(credentials.accessToken) else {
            return false
        }
        return expiresAt.timeIntervalSinceNow < 10 * 60
    }

    private func refreshAccessToken(credentials: CursorCredentials) async throws -> String {
        guard let refreshToken = credentials.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encodeCredentials(credentials)
        }

        var request = URLRequest(url: apiBaseURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB",
            "refresh_token": refreshToken
        ])

        let data = try await dataWithRetry(for: request, operation: "Cursor token 刷新")
        let response = try JSONDecoder().decode(CursorTokenRefreshResponse.self, from: data)
        if response.shouldLogout == true {
            throw ProviderError.invalidCredentials
        }
        guard let accessToken = response.accessToken,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidCredentials
        }

        let refreshed = CursorCredentials(
            accessToken: accessToken,
            refreshToken: credentials.refreshToken,
            email: credentials.email,
            membershipType: credentials.membershipType,
            subscriptionStatus: credentials.subscriptionStatus,
            subscriptionPeriodEnd: credentials.subscriptionPeriodEnd,
            stateDatabasePath: credentials.stateDatabasePath,
            source: credentials.source
        )
        return encodeCredentials(refreshed)
    }

    private func jwtExpirationDate(_ token: String) -> Date? {
        guard let exp = jwtDoubleClaim(token, claim: "exp") else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func jwtStringClaim(_ token: String, claim: String) -> String? {
        jwtPayload(token)?[claim] as? String
    }

    private func jwtDoubleClaim(_ token: String, claim: String) -> Double? {
        guard let value = jwtPayload(token)?[claim] else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func fetchCurrentPeriodUsage(accessToken: String) async throws -> Any {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("aiserver.v1.DashboardService/GetCurrentPeriodUsage"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        let data = try await dataWithRetry(for: request, operation: "Cursor 当前周期用量查询")
        return try JSONSerialization.jsonObject(with: data)
    }

    private func fetchLegacyUsage(accessToken: String) async throws -> Any {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("auth/usage"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await dataWithRetry(for: request, operation: "Cursor legacy 用量查询")
        return try JSONSerialization.jsonObject(with: data)
    }

#if DEBUG
    func parseCurrentPeriodUsageForTesting(
        _ payload: Any,
        email: String? = "fixture@example.com",
        membershipType: String? = nil,
        subscriptionStatus: String? = nil,
        subscriptionPeriodEnd: Date? = nil
    ) throws -> QuotaSnapshot {
        let credentials = CursorCredentials(
            accessToken: "fixture-access-token",
            refreshToken: nil,
            email: email,
            membershipType: membershipType,
            subscriptionStatus: subscriptionStatus,
            subscriptionPeriodEnd: subscriptionPeriodEnd,
            stateDatabasePath: nil,
            source: "fixture"
        )
        return try parseCurrentPeriodUsage(payload, credentials: credentials)
    }
#endif

    private func parseCurrentPeriodUsage(_ payload: Any, credentials: CursorCredentials) throws -> QuotaSnapshot {
        let plan = firstDictionary(
            in: payload,
            keys: ["planUsage", "plan", "includedUsage", "included_usage"]
        )
        let onDemand = firstDictionary(in: payload, keys: ["onDemand", "on_demand", "spendLimitUsage", "spend_limit_usage"])
        let planName = normalizedPlanName(
            firstString(in: payload, keys: ["membershipType", "membership_type", "planName", "plan_name"])
                ?? credentials.membershipType
        )
        let periodEnd = firstDate(in: payload, keys: Self.cycleBoundaryDateKeys)
        let accountValidUntil = firstDate(
            in: payload,
            keys: [
                "subscriptionEnd",
                "subscription_end",
                "subscriptionExpiresAt",
                "subscription_expires_at",
                "activeUntil",
                "active_until",
                "expiresAt",
                "expires_at",
                "nextBillingDate",
                "next_billing_date"
            ]
        ) ?? credentials.subscriptionPeriodEnd
        let subscriptionStatus = firstString(in: payload, keys: ["subscriptionStatus", "subscription_status", "status", "stripeSubscriptionStatus"])
            ?? credentials.subscriptionStatus

        let totalPercentUsed = firstDouble(in: payload, keys: ["totalPercentUsed", "total_percent_used"])
        let autoPercentUsed = firstDouble(in: payload, keys: ["autoPercentUsed", "auto_percent_used"])
        let apiPercentUsed = firstDouble(in: payload, keys: ["apiPercentUsed", "api_percent_used"])

        let hasRealCapacity = planHasPositiveCapacity(plan) || onDemandHasPositiveCapacity(onDemand)
        let hasPercentUsageSignal = [totalPercentUsed, autoPercentUsed, apiPercentUsed].contains { value in
            guard let value else { return false }
            return value > 0
        }
        let canTrustPercentWindows = hasRealCapacity || hasPercentUsageSignal

        let primary = parsePlanWindow(plan, resetAt: periodEnd)
            ?? (canTrustPercentWindows ? parsePercentWindow(
                label: "Total",
                usedPercent: totalPercentUsed,
                resetAt: periodEnd
            ) : nil)
        let auto = canTrustPercentWindows ? parsePercentWindow(
            label: "Auto",
            usedPercent: autoPercentUsed,
            resetAt: periodEnd
        ) : nil
        let api = canTrustPercentWindows ? parsePercentWindow(
            label: "API",
            usedPercent: apiPercentUsed,
            resetAt: periodEnd
        ) : nil
        let note = cursorUsageNote(plan: plan, onDemand: onDemand)

        // Some free / zero-quota payloads include *PercentUsed=0 placeholders.
        // Those should not be rendered as "100% remaining".
        if primary == nil, auto == nil, api == nil,
           !hasRealCapacity,
           !hasPercentUsageSignal,
           usagePayloadHasOnlyZeroOrNoQuotaSignals(
               plan: plan,
               onDemand: onDemand,
               totalPercentUsed: totalPercentUsed,
               autoPercentUsed: autoPercentUsed,
               apiPercentUsed: apiPercentUsed
           ) {
            return QuotaSnapshot(
                source: "Cursor",
                accountIdentifier: cursorAccountEmail(from: credentials),
                planName: planName,
                primary: nil,
                secondary: nil,
                tertiary: nil,
                creditsRemaining: nil,
                creditsTotal: nil,
                updatedAt: .init(),
                periodEnd: periodEnd,
                accountValidUntil: accountValidUntil,
                subscriptionWillRenew: inferSubscriptionWillRenew(from: subscriptionStatus),
                subscriptionStatus: normalizedSubscriptionStatus(subscriptionStatus),
                isQuotaBlocked: isQuotaBlocked(in: payload),
                note: note
            )
        }

        guard primary != nil || auto != nil || api != nil else {
            throw ProviderError.network("Cursor 返回成功，但未识别到用量字段")
        }

        return QuotaSnapshot(
            source: "Cursor",
            accountIdentifier: cursorAccountEmail(from: credentials),
            planName: planName,
            primary: primary,
            secondary: auto,
            tertiary: api,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: .init(),
            periodEnd: periodEnd,
            accountValidUntil: accountValidUntil,
            subscriptionWillRenew: inferSubscriptionWillRenew(from: subscriptionStatus),
            subscriptionStatus: normalizedSubscriptionStatus(subscriptionStatus),
            isQuotaBlocked: isQuotaBlocked(in: payload),
            note: note
        )
    }

    private func planHasPositiveCapacity(_ plan: [String: Any]?) -> Bool {
        guard let plan else { return false }
        let limit = firstDouble(in: plan, keys: ["limit", "total", "includedAmountCents", "included_amount_cents"]) ?? 0
        let remaining = firstDouble(in: plan, keys: ["remaining", "totalRemaining", "total_remaining"]) ?? 0
        let used = firstDouble(in: plan, keys: ["used", "totalUsed", "total_used", "totalSpend", "total_spend", "includedSpend", "included_spend"]) ?? 0
        return limit > 0 || remaining > 0 || used > 0
    }

    private func planExplicitlyHasNoCapacity(_ plan: [String: Any]?) -> Bool {
        guard let plan else { return false }
        let limit = firstDouble(in: plan, keys: ["limit", "total", "includedAmountCents", "included_amount_cents"])
        let remaining = firstDouble(in: plan, keys: ["remaining", "totalRemaining", "total_remaining"])
        let used = firstDouble(in: plan, keys: ["used", "totalUsed", "total_used", "totalSpend", "total_spend", "includedSpend", "included_spend"])
        guard limit != nil || remaining != nil || used != nil else { return false }
        return (limit ?? 0) <= 0 && (remaining ?? 0) <= 0 && (used ?? 0) <= 0
    }

    private func usagePayloadHasOnlyZeroOrNoQuotaSignals(
        plan: [String: Any]?,
        onDemand: [String: Any]?,
        totalPercentUsed: Double?,
        autoPercentUsed: Double?,
        apiPercentUsed: Double?
    ) -> Bool {
        let hasZeroPercentTriplet =
            totalPercentUsed != nil && autoPercentUsed != nil && apiPercentUsed != nil
            && (totalPercentUsed ?? 1) == 0
            && (autoPercentUsed ?? 1) == 0
            && (apiPercentUsed ?? 1) == 0

        let hasZeroOnDemandLimits: Bool = {
            guard let onDemand else { return false }
            let pooledLimit = firstDouble(in: onDemand, keys: ["pooledLimit", "pooled_limit"]) ?? 0
            let individualLimit = firstDouble(in: onDemand, keys: ["individualLimit", "individual_limit"]) ?? 0
            let overallLimit = firstDouble(in: onDemand, keys: ["overallLimit", "overall_limit", "limit"]) ?? 0
            let pooledRemaining = firstDouble(in: onDemand, keys: ["pooledRemaining", "pooled_remaining"]) ?? 0
            let overallRemaining = firstDouble(in: onDemand, keys: ["overallRemaining", "overall_remaining", "remaining"]) ?? 0
            return pooledLimit <= 0
                && individualLimit <= 0
                && overallLimit <= 0
                && pooledRemaining <= 0
                && overallRemaining <= 0
        }()

        return planExplicitlyHasNoCapacity(plan) || hasZeroOnDemandLimits || hasZeroPercentTriplet
    }

    private func onDemandHasPositiveCapacity(_ onDemand: [String: Any]?) -> Bool {
        guard let onDemand else { return false }
        let limit = firstDouble(in: onDemand, keys: ["limit", "pooledLimit", "pooled_limit", "individualLimit", "individual_limit", "overallLimit", "overall_limit"]) ?? 0
        let remaining = firstDouble(in: onDemand, keys: ["remaining", "pooledRemaining", "pooled_remaining", "individualRemaining", "individual_remaining", "overallRemaining", "overall_remaining"]) ?? 0
        let used = firstDouble(in: onDemand, keys: ["used", "pooledUsed", "pooled_used", "individualUsed", "individual_used", "overallUsed", "overall_used"]) ?? 0
        return limit > 0 || remaining > 0 || used > 0
    }

    private func parseLegacyUsage(_ payload: Any, credentials: CursorCredentials) -> QuotaSnapshot {
        let windows = UsageWindowExtractor.extract(from: payload)
        let sorted = windows.sorted { ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture) }
        let periodEnd = firstDate(in: payload, keys: Self.cycleBoundaryDateKeys)
            ?? sorted.compactMap(\.resetAt).max()

        return QuotaSnapshot(
            source: "Cursor Legacy",
            accountIdentifier: cursorAccountEmail(from: credentials),
            planName: normalizedPlanName(credentials.membershipType),
            primary: sorted.first,
            secondary: sorted.dropFirst().first,
            tertiary: sorted.dropFirst(2).first,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: .init(),
            periodEnd: periodEnd,
            accountValidUntil: credentials.subscriptionPeriodEnd,
            subscriptionWillRenew: inferSubscriptionWillRenew(from: credentials.subscriptionStatus),
            subscriptionStatus: normalizedSubscriptionStatus(credentials.subscriptionStatus),
            note: sorted.isEmpty ? "Cursor legacy 接口返回成功，但未识别到标准额度字段" : nil
        )
    }

    private func parsePlanWindow(_ dict: [String: Any]?, resetAt: Date?) -> QuotaWindow? {
        guard let dict else { return nil }
        let used = firstDouble(in: dict, keys: ["used", "totalUsed", "total_used", "totalSpend", "total_spend", "includedSpend", "included_spend"])
        let limit = firstDouble(in: dict, keys: ["limit", "total", "includedAmountCents", "included_amount_cents"])
        let remaining = firstDouble(in: dict, keys: ["remaining", "totalRemaining", "total_remaining"])

        if let used, let limit, limit > 0 {
            return QuotaWindow(label: "Total", used: used, limit: limit, resetAt: resetAt)
        }
        if let remaining, let limit, limit > 0 {
            return QuotaWindow(label: "Total", used: max(limit - remaining, 0), limit: limit, resetAt: resetAt)
        }
        return nil
    }

    private func parsePercentWindow(label: String, usedPercent: Double?, resetAt: Date?) -> QuotaWindow? {
        guard var usedPercent else { return nil }
        if usedPercent <= 1 {
            usedPercent *= 100
        }
        return QuotaWindow(label: label, used: min(max(usedPercent, 0), 100), limit: 100, resetAt: resetAt)
    }

    private func normalizedSubscriptionStatus(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func inferSubscriptionWillRenew(from status: String?) -> Bool? {
        guard let status = normalizedSubscriptionStatus(status) else { return nil }
        switch status {
        case "active", "trialing", "paid":
            return true
        case "canceled", "cancelled", "incomplete_expired", "expired", "unpaid", "past_due":
            return false
        default:
            return nil
        }
    }

    private func cursorUsageNote(plan: [String: Any]?, onDemand: [String: Any]?) -> String? {
        var parts: [String] = []
        if let plan,
           let used = firstDouble(in: plan, keys: ["used", "totalUsed", "total_used", "totalSpend", "total_spend", "includedSpend", "included_spend"]),
           let limit = firstDouble(in: plan, keys: ["limit", "total", "includedAmountCents", "included_amount_cents"]),
           limit > 0 {
            parts.append("Included \(formatDollars(used))/\(formatDollars(limit))")
        }

        if let onDemand,
           firstBool(in: onDemand, keys: ["enabled"]) == true,
           let used = firstDouble(in: onDemand, keys: ["used", "pooledUsed", "individualUsed"]),
           used > 0 {
            let limit = firstDouble(in: onDemand, keys: ["limit", "pooledLimit", "individualLimit"])
            if let limit, limit > 0 {
                parts.append("On-demand \(formatDollars(used))/\(formatDollars(limit))")
            } else {
                parts.append("On-demand \(formatDollars(used))")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatDollars(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }

    private func normalizedPlanName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case let value where value.contains("ultra"):
            return "Ultra"
        case let value where value.contains("pro_plus") || value.contains("pro plus") || value.contains("pro+"):
            return "Pro+"
        case let value where value.contains("pro"):
            return "Pro"
        case let value where value.contains("team") || value.contains("business"):
            return "Team"
        case let value where value.contains("enterprise"):
            return "Enterprise"
        case let value where value.contains("free") || value.contains("hobby"):
            return "Free"
        default:
            return raw
        }
    }

    private func isQuotaBlocked(in payload: Any) -> Bool? {
        firstBool(in: payload, keys: ["isBlocked", "is_blocked", "limitReached", "limit_reached", "isHardLimited", "is_hard_limited"])
    }

    private func dataWithRetry(for request: URLRequest, operation: String) async throws -> Data {
        var lastError: Error?
        for attempt in 0 ..< Self.maxNetworkAttempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ProviderError.network("\(operation)失败：无 HTTP 响应")
                }
                if 200 ..< 300 ~= http.statusCode {
                    return data
                }
                let retryable = http.statusCode == 408 || http.statusCode == 429 || (500 ... 599).contains(http.statusCode)
                let failure = HTTPRequestFailure(
                    operation: operation,
                    statusCode: http.statusCode,
                    isRetryable: retryable
                )
                guard retryable, attempt < Self.maxNetworkAttempts - 1 else {
                    throw failure
                }
                lastError = failure
            } catch {
                if error is CancellationError {
                    throw error
                }
                guard isRetryableNetworkError(error), attempt < Self.maxNetworkAttempts - 1 else {
                    throw error
                }
                lastError = error
            }

            let seconds = [0.35, 0.9, 1.8][min(attempt, 2)]
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        throw lastError ?? ProviderError.network("\(operation)失败")
    }

    private func isRetryableNetworkError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let failure = error as? HTTPRequestFailure {
            return failure.isRetryable
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return true
        default:
            return false
        }
    }

    private func shouldUseCachedQuota(for error: Error) -> Bool {
        isRetryableNetworkError(error)
    }

    private func quotaCacheKey(_ credentials: CursorCredentials) -> String {
        let raw = accountIdentity(from: encodeCredentials(credentials)) ?? String(credentials.accessToken.suffix(24))
        return "cursor-" + Data(raw.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func quotaCachePath(cacheKey: String) -> String {
        AppPaths.quotaCacheDirectory.appendingPathComponent("\(cacheKey).json").path
    }

    private func loadCachedQuotaSnapshot(cacheKey: String) throws -> CachedQuotaSnapshot {
        let text = try fileService.readText(at: quotaCachePath(cacheKey: cacheKey))
        guard let data = text.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
        }
        return try JSONDecoder().decode(CachedQuotaSnapshot.self, from: data)
    }

    private func storeQuotaSnapshot(_ snapshot: QuotaSnapshot, cacheKey: String) throws {
        try fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        let cached = CachedQuotaSnapshot(schemaVersion: 1, cachedAt: .init(), snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cached)
        try fileService.writeText(String(data: data, encoding: .utf8) ?? "{}", to: quotaCachePath(cacheKey: cacheKey))
    }

    private func mergedNote(_ existing: String?, fallback: String) -> String {
        guard let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines),
              !existing.isEmpty else {
            return fallback
        }
        if existing.contains(fallback) {
            return existing
        }
        return "\(existing)；\(fallback)"
    }

    private func firstDictionary(in object: Any, keys: Set<String>) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let nested = value as? [String: Any] {
                    return nested
                }
                if let nested = firstDictionary(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = firstDictionary(in: value, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private func firstString(in object: Any, keys: Set<String>) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let text = value as? String, !text.isEmpty {
                    return text
                }
                if let nested = firstString(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = firstString(in: value, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private func firstDouble(in object: Any, keys: Set<String>) -> Double? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let number = asDouble(value) {
                    return number
                }
                if let nested = firstDouble(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = firstDouble(in: value, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private func firstBool(in object: Any, keys: Set<String>) -> Bool? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let bool = asBool(value) {
                    return bool
                }
                if let nested = firstBool(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = firstBool(in: value, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private func firstDate(in object: Any, keys: Set<String>) -> Date? {
        if let raw = firstString(in: object, keys: keys) {
            return parseDate(raw)
        }
        if let raw = firstDouble(in: object, keys: keys) {
            return raw > 2_000_000_000 ? Date(timeIntervalSince1970: raw / 1000) : Date(timeIntervalSince1970: raw)
        }
        return nil
    }

    private func asDouble(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func asBool(_ value: Any) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed) {
            return number > 2_000_000_000 ? Date(timeIntervalSince1970: number / 1000) : Date(timeIntervalSince1970: number)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
