import AppKit
import Foundation

final class LoginOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CodexLoginAttempt: Sendable {
    let name: String
    let arguments: [String]
    let timeout: TimeInterval
    let opensDevicePrompt: Bool
}

struct CodexImportedAccount: Sendable {
    let name: String
    let secret: String
    let isActive: Bool
}

struct CodexProvider: Provider {
    let tool: ToolKind = .codex
    let treatsImportedCredentialsAsActiveSelection = true
    private let fileService = FileService()

    private var codexHomePath: String {
        if let raw = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        return "~/.codex"
    }

    private var activeAuthPath: String {
        "\(codexHomePath)/auth.json"
    }

    private var activeConfigPath: String {
        "\(codexHomePath)/config.toml"
    }

    private var accountsDirectoryPath: String {
        "\(codexHomePath)/accounts"
    }

    private var registryPath: String {
        "\(accountsDirectoryPath)/registry.json"
    }

    private var subscriptionsCachePath: String {
        "\(accountsDirectoryPath)/subscriptions.json"
    }

    private let refreshClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let tokenRefreshInterval: TimeInterval = 8 * 24 * 60 * 60
    private let tokenRefreshLeeway: TimeInterval = 10 * 60
    private let chatGPTUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"

    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private static let fallbackQuotaCacheAge: TimeInterval = 24 * 60 * 60
    private static let maxNetworkAttempts = 3
    private static let httpClient = QuotaHTTPClient(session: liveSession, maxAttempts: maxNetworkAttempts)

    private struct CachedQuotaSnapshot: Codable {
        let schemaVersion: Int
        let cachedAt: Date
        let snapshot: QuotaSnapshot
    }

    func importCurrentCredentials() async throws -> String {
        try fileService.readText(at: activeAuthPath)
    }

    func updateCurrentCredentials(_ secret: String) async throws {
        try ensureFileCredentialStore(at: activeConfigPath)
        try fileService.writeTextWithBackup(secret, to: activeAuthPath, backupBaseName: "auth.json")
    }

    func persistRefreshedSecret(_ secret: String, for account: Account, isActive: Bool) async throws {
        let managedHome = account.settings.codexHomePath ?? AppPaths.managedCodexHomePath(accountID: account.id)
        try ensureFileCredentialStore(at: "\(managedHome)/config.toml")
        try fileService.writeTextWithBackup(secret, to: "\(managedHome)/auth.json", backupBaseName: "auth.json")
        try upsertRegistryAccount(account: account, secret: secret, makeActive: isActive)
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

    func importStoredAccounts() async throws -> [CodexImportedAccount] {
        guard fileService.fileExists(at: registryPath) else { return [] }
        let registry = try loadRegistryDocument()
        let activeAccountKey = registry.activeAccountKey

        return registry.accounts.compactMap { entry in
            guard let accountKey = entry.accountKey,
                  !accountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            let authMode = entry.authMode?.lowercased()
            guard authMode == nil || authMode == "chatgpt" else { return nil }

            let authPath = registryAuthSnapshotPath(accountKey: accountKey)
            guard fileService.fileExists(at: authPath),
                  let secret = try? fileService.readText(at: authPath),
                  !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            let name = [
                entry.alias,
                entry.accountName,
                entry.email
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
                ?? suggestAccountName(from: secret)
                ?? "Codex \(accountKey.suffix(6))"

            return CodexImportedAccount(
                name: name,
                secret: secret,
                isActive: accountKey == activeAccountKey
            )
        }
    }

    func authenticateViaBrowser() async throws -> String {
        try AppPaths.ensureDirectories()
        let scratchHome = AppPaths.appSupportDirectory
            .appendingPathComponent("login-scratch", isDirectory: true)
            .appendingPathComponent("codex-\(UUID().uuidString)", isDirectory: true)
        try fileService.createDirectoryIfNeeded(at: scratchHome.path)

        guard let codexExecutable = findCodexExecutable() else {
            throw ProviderError.unsupported("未找到 Codex CLI。请先安装 Codex，或确认 codex 命令可用。")
        }

        defer {
            try? fileService.removeItemIfExists(at: scratchHome.path)
        }

        var failures: [String] = []
        for attempt in codexLoginAttempts() {
            do {
                return try await runLoginAttempt(
                    attempt,
                    codexExecutable: codexExecutable,
                    scratchHome: scratchHome
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(attempt.name)：\(loginFailureMessage(error))")
            }
        }

        let message = failures.isEmpty
            ? "Codex 登录未完成，请重试"
            : "Codex 登录失败：\(failures.joined(separator: "；"))"
        throw ProviderError.unsupported(message)
    }

    private func codexLoginAttempts() -> [CodexLoginAttempt] {
        let fileCredentialStoreOverride = #"cli_auth_credentials_store="file""#
        return [
            CodexLoginAttempt(
                name: "浏览器登录",
                arguments: ["login", "-c", fileCredentialStoreOverride],
                timeout: 180,
                opensDevicePrompt: false
            ),
            CodexLoginAttempt(
                name: "兼容浏览器登录",
                arguments: ["login"],
                timeout: 180,
                opensDevicePrompt: false
            ),
            CodexLoginAttempt(
                name: "设备码登录",
                arguments: ["login", "-c", fileCredentialStoreOverride, "--device-auth"],
                timeout: 15 * 60,
                opensDevicePrompt: true
            ),
            CodexLoginAttempt(
                name: "兼容设备码登录",
                arguments: ["login", "--device-auth"],
                timeout: 15 * 60,
                opensDevicePrompt: true
            )
        ]
    }

    private func runLoginAttempt(
        _ attempt: CodexLoginAttempt,
        codexExecutable: URL,
        scratchHome: URL
    ) async throws -> String {
        let process = Process()
        process.executableURL = codexExecutable
        process.arguments = attempt.arguments
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = scratchHome.path
        env["PATH"] = augmentedPath(from: env["PATH"])
        process.environment = env

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = FileHandle.nullDevice
        let loginOutput = LoginOutputBuffer()
        let loginURLScanner = CodexLoginFallbackURLScanner()
        let devicePromptScanner = attempt.opensDevicePrompt ? CodexDeviceAuthPromptScanner() : nil
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(data: data, encoding: .utf8) ?? ""
            loginOutput.append(chunk)
            if let url = loginURLScanner.append(data) {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }
            }
            if let prompt = devicePromptScanner?.append(data) {
                DispatchQueue.main.async {
                    Self.presentDeviceAuthPrompt(prompt)
                }
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw ProviderError.unsupported("未找到 codex 命令，请先安装 Codex CLI")
        }
        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }

        let deadline = Date().addingTimeInterval(attempt.timeout)
        let scratchAuthPath = "\(scratchHome.path)/auth.json"
        while Date() < deadline {
            if Task.isCancelled {
                throw CancellationError()
            }

            if let auth = try readValidatedAuthIfAvailable(at: scratchAuthPath) {
                return auth
            }

            if !process.isRunning {
                break
            }

            try await Task.sleep(nanoseconds: 120_000_000)
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        let remainingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingData.isEmpty {
            loginOutput.append(String(data: remainingData, encoding: .utf8) ?? "")
        }

        if process.isRunning {
            throw ProviderError.unsupported(attempt.opensDevicePrompt ? "Codex 设备码登录超时，请重试" : "Codex 浏览器登录超时，请重试")
        }

        if process.terminationStatus == 0 {
            for _ in 0 ..< 15 {
                if let auth = try readValidatedAuthIfAvailable(at: scratchAuthPath) {
                    return auth
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        if let auth = try readValidatedAuthIfAvailable(at: scratchAuthPath) {
            return auth
        }

        let output = loginOutput.snapshot()
        if process.terminationStatus != 0 {
            if output.isEmpty {
                throw ProviderError.unsupported("Codex 登录未完成，请在浏览器完成授权后重试")
            }
            throw ProviderError.unsupported("Codex 登录失败：\(output)")
        }

        throw ProviderError.missingFile(path: scratchAuthPath)
    }

    private func ensureFileCredentialStore(at configPath: String) throws {
        let current = (try? fileService.readText(at: configPath)) ?? ""
        let updated = current.upsertingTopLevelTOMLString(
            key: "cli_auth_credentials_store",
            value: "file"
        )
        guard updated != current else { return }
        try fileService.writeTextWithBackup(updated, to: configPath, backupBaseName: "config.toml")
    }

    private func loginFailureMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description.strippingANSIControlSequences().singleLineCondensed(maxLength: 320)
        }
        return error.localizedDescription.strippingANSIControlSequences().singleLineCondensed(maxLength: 320)
    }

    @MainActor
    private static func presentDeviceAuthPrompt(_ prompt: CodexDeviceAuthPrompt) {
        NSWorkspace.shared.open(prompt.url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt.code, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Codex 设备登录"
        alert.informativeText = "已打开登录页面，验证码已复制到剪贴板：\(prompt.code)"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func readValidatedAuthIfAvailable(at path: String) throws -> String? {
        guard fileService.fileExists(at: path) else { return nil }
        let auth = try fileService.readText(at: path)
        guard let data = auth.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
        }
        let credentials = try parseCredentials(data: data)
        if let accessToken = credentials.accessToken, !accessToken.isEmpty {
            return auth
        }
        if let apiKey = credentials.apiKey, !apiKey.isEmpty {
            return auth
        }
        throw ProviderError.invalidCredentials
    }

    private func findCodexExecutable() -> URL? {
        let fileManager = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathCandidates = augmentedPath(from: ProcessInfo.processInfo.environment["PATH"])
            .split(separator: ":")
            .map { String($0) }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }

        let explicitCandidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.deno/bin/codex",
            "\(home)/.cargo/bin/codex",
            "\(home)/.volta/bin/codex"
        ].map(URL.init(fileURLWithPath:))

        for url in pathCandidates + explicitCandidates {
            guard fileManager.isExecutableFile(atPath: url.path) else { continue }
            return url
        }

        return nil
    }

    private func augmentedPath(from currentPath: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
            "\(home)/.cargo/bin",
            "\(home)/.volta/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        let existingPaths = (currentPath ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        return (existingPaths + commonPaths)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    func prepareAccount(_ account: Account, secret: String) async throws -> Account {
        var updated = account
        let managedHome = account.settings.codexHomePath ?? AppPaths.managedCodexHomePath(accountID: account.id)
        updated.settings.codexHomePath = managedHome
        updated.settings.codexRegistryKey = registryAccountKey(from: secret) ?? account.settings.codexRegistryKey
        updated.settings.identityKey = accountIdentity(from: secret) ?? account.settings.identityKey

        try fileService.createDirectoryIfNeeded(at: managedHome)

        if fileService.fileExists(at: activeConfigPath) {
            try fileService.copyItemReplacingWithBackup(from: activeConfigPath, to: "\(managedHome)/config.toml", backupBaseName: "config.toml")
        }
        try ensureFileCredentialStore(at: "\(managedHome)/config.toml")

        // Keep a per-account auth snapshot for local recovery.
        try fileService.writeTextWithBackup(secret, to: "\(managedHome)/auth.json", backupBaseName: "auth.json")
        try upsertRegistryAccount(account: updated, secret: secret, makeActive: false)

        return updated
    }

    func activate(account: Account, secret: String) async throws {
        guard secret.data(using: .utf8) != nil else {
            throw ProviderError.invalidCredentials
        }

        let managedHome = account.settings.codexHomePath ?? AppPaths.managedCodexHomePath(accountID: account.id)
        try fileService.createDirectoryIfNeeded(at: managedHome)

        try fileService.writeTextWithBackup(secret, to: activeAuthPath, backupBaseName: "auth.json")
        try fileService.writeTextWithBackup(secret, to: "\(managedHome)/auth.json", backupBaseName: "auth.json")
        try upsertRegistryAccount(account: account, secret: secret, makeActive: true)

        let managedConfigPath = "\(managedHome)/config.toml"
        if fileService.fileExists(at: managedConfigPath) {
            try fileService.copyItemReplacingWithBackup(from: managedConfigPath, to: activeConfigPath, backupBaseName: "config.toml")
        }
        try ensureFileCredentialStore(at: activeConfigPath)
    }

    func deleteAccountArtifacts(account: Account) async throws {
        if let path = account.settings.codexHomePath, !path.isEmpty {
            try fileService.removeItemIfExists(at: path)
        }
        if let registryKey = account.settings.codexRegistryKey, !registryKey.isEmpty {
            try removeRegistryAccount(accountKey: registryKey)
        }
    }

    func recoverSecret(for account: Account) async throws -> String? {
        var hasScopedArtifact = false

        if let registryKey = account.settings.codexRegistryKey, !registryKey.isEmpty {
            hasScopedArtifact = true
            let registryAuthPath = registryAuthSnapshotPath(accountKey: registryKey)
            if fileService.fileExists(at: registryAuthPath) {
                let registrySecret = try fileService.readText(at: registryAuthPath)
                if recoveredSecretMatches(registrySecret, account: account, source: .registrySnapshot) {
                    return registrySecret
                }
            }
        }

        if let managed = account.settings.codexHomePath, !managed.isEmpty {
            hasScopedArtifact = true
            let managedAuthPath = "\(managed)/auth.json"
            if fileService.fileExists(at: managedAuthPath) {
                let managedSecret = try fileService.readText(at: managedAuthPath)
                if recoveredSecretMatches(managedSecret, account: account, source: .managed) {
                    return managedSecret
                }
            }
        }

        if hasScopedArtifact {
            return nil
        }

        if fileService.fileExists(at: activeAuthPath) {
            let activeSecret = try fileService.readText(at: activeAuthPath)
            if recoveredSecretMatches(activeSecret, account: account, source: .activeGlobal) {
                return activeSecret
            }
        }

        return nil
    }

    func suggestAccountName(from secret: String) -> String? {
        guard let data = secret.data(using: .utf8),
              let credentials = try? parseCredentials(data: data) else {
            return nil
        }

        if let email = extractEmail(fromIDToken: credentials.idToken) {
            return email
        }
        if let accountID = credentials.accountID, !accountID.isEmpty {
            return "codex-\(accountID.suffix(6))"
        }
        return nil
    }

    func accountIdentity(from secret: String) -> String? {
        guard let data = secret.data(using: .utf8),
              let credentials = try? parseCredentials(data: data) else {
            return nil
        }

        if let accountKey = registryAccountKey(from: secret) {
            return "codex:\(accountKey)"
        }

        if let accountID = credentials.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            return "codex:\(accountID)"
        }

        if let email = extractEmail(fromIDToken: credentials.idToken) {
            return "email:\(email.lowercased())"
        }

        if let apiKey = credentials.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            return "api:\(apiKey.suffix(12))"
        }

        return nil
    }

    private enum SecretRecoverySource {
        case managed
        case registrySnapshot
        case activeGlobal
    }

    private func recoveredSecretMatches(_ secret: String, account: Account, source: SecretRecoverySource) -> Bool {
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let expectedIdentity = account.settings.identityKey.map(normalizedIdentity)
        let expectedRegistryKey = account.settings.codexRegistryKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let actualIdentity = accountIdentity(from: secret).map(normalizedIdentity)
        let actualRegistryKey = registryAccountKey(from: secret)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let expectedIdentity {
            guard actualIdentity == expectedIdentity else {
                return false
            }
        }

        if let expectedRegistryKey, !expectedRegistryKey.isEmpty {
            guard actualRegistryKey == expectedRegistryKey else {
                return false
            }
        }

        if expectedIdentity != nil || (expectedRegistryKey?.isEmpty == false) {
            return true
        }

        // Backward compatibility for legacy records lacking identity metadata.
        // Active global auth is never trusted without explicit identity match.
        if source == .activeGlobal {
            let normalizedName = account.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedName.contains("@"),
               actualIdentity == "email:\(normalizedName)" {
                return true
            }
            return false
        }

        // Managed and registry snapshots are account-scoped local artifacts.
        if source == .managed || source == .registrySnapshot {
            return true
        }

        return false
    }

    private func normalizedIdentity(_ identity: String) -> String {
        identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func refreshSecretIfNeeded(_ secret: String) async throws -> String {
        try await refreshSecret(secret, force: false)
    }

    private func refreshSecret(_ secret: String, force: Bool) async throws -> String {
        guard let data = secret.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
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

    func fetchQuota(secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: Account(tool: .codex, name: "Codex"), secret: secret)
    }

    func fetchQuota(account: Account, secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: account, secret: secret, forceRefresh: false)
    }

    func fetchQuota(account: Account, secret: String, forceRefresh: Bool) async throws -> QuotaSnapshot {
        guard let data = secret.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
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
                    return try await fetchCreditGrants(apiKey: apiKey, note: "OAuth 查询失败，已回退 API Key")
                }
                throw error
            }
        }

        if let apiKey = credentials.apiKey, !apiKey.isEmpty {
            return try await fetchCreditGrants(apiKey: apiKey, note: nil)
        }

        throw ProviderError.invalidCredentials
    }

    private struct CodexCredentials {
        let apiKey: String?
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?
        let accountID: String?
        let lastRefresh: Date?
    }

    private func parseCredentialEnvelope(data: Data) throws -> (root: [String: Any], credentials: CodexCredentials) {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any] else {
            throw ProviderError.invalidCredentials
        }

        let apiKey = (dict["OPENAI_API_KEY"] as? String)
            ?? (dict["openai_api_key"] as? String)
            ?? (dict["openaiApiKey"] as? String)
        let tokens = dict["tokens"] as? [String: Any]
        let accessToken = stringValue(in: tokens, snakeKey: "access_token", camelKey: "accessToken")
            ?? stringValue(in: dict, snakeKey: "access_token", camelKey: "accessToken")
        let refreshToken = stringValue(in: tokens, snakeKey: "refresh_token", camelKey: "refreshToken")
            ?? stringValue(in: dict, snakeKey: "refresh_token", camelKey: "refreshToken")
        let idToken = stringValue(in: tokens, snakeKey: "id_token", camelKey: "idToken")
            ?? stringValue(in: dict, snakeKey: "id_token", camelKey: "idToken")
        let accountID = stringValue(in: tokens, snakeKey: "account_id", camelKey: "accountId")
            ?? stringValue(in: dict, snakeKey: "account_id", camelKey: "accountId")
        let credentials = CodexCredentials(
            apiKey: apiKey,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            lastRefresh: parseLastRefresh(dict["last_refresh"])
        )
        return (dict, credentials)
    }

    private func parseCredentials(data: Data) throws -> CodexCredentials {
        try parseCredentialEnvelope(data: data).credentials
    }

    private func fetchOAuthUsage(
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
            note: windows.isEmpty ? "接口返回成功，但未识别到标准额度字段" : nil
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

    private func makeOAuthUsageRequest(url: URL, accessToken: String, accountID: String?) -> URLRequest {
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

    private func fetchSubscriptionIfNeeded(
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

    private func makeOAuthSubscriptionRequest(url: URL, accessToken: String, accountID: String) -> URLRequest {
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

    private func dataWithOfficialSubscriptionFallback(
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

    private func parseSubscriptionMetadata(from payload: Any) -> SubscriptionCacheMetadata? {
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

    private func dataWithOfficialFallback(
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

    private func shouldRetryAgainstOfficialUsageURL(for error: Error, primaryURL: URL) -> Bool {
        guard isRetryableNetworkError(error) else { return false }
        let host = primaryURL.host?.lowercased() ?? ""
        return host != "chatgpt.com" && host != "chat.openai.com"
    }

    private func dataWithRetry(for request: URLRequest, operation: String) async throws -> Data {
        try await Self.httpClient.data(for: request, operation: operation)
    }

    private func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 409 || statusCode == 425 || statusCode == 429 || (500 ... 599).contains(statusCode)
    }

    private func isRetryableNetworkError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        return QuotaHTTPClient.isRetryableNetworkError(error)
    }

    private func shouldTreatAsTransientNetworkError(_ error: Error) -> Bool {
        isRetryableNetworkError(error)
    }

    private func shouldUseCachedQuota(for error: Error) -> Bool {
        isRetryableNetworkError(error)
    }

    private func retryDelayNanoseconds(for attempt: Int) -> UInt64 {
        let seconds = [0.35, 0.9, 1.8][min(attempt, 2)]
        return UInt64(seconds * 1_000_000_000)
    }

    private func refreshOAuthCredentials(_ credentials: CodexCredentials) async throws -> CodexCredentials {
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
                throw ProviderError.unsupported("Codex refresh token 已被使用，请重新登录")
            case "refresh_token_invalidated":
                throw ProviderError.unsupported("Codex refresh token 已失效，请重新登录")
            case "invalid_grant", "invalid_request":
                throw ProviderError.unsupported("Codex refresh token 无效，请重新登录")
            default:
                throw ProviderError.unsupported("Codex refresh token 已过期，请重新登录")
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

    private func tokenRefreshResponse(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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

    private func writeCredentials(_ credentials: CodexCredentials, into root: [String: Any]) throws -> Data {
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

    private func registryAccountKey(from secret: String) -> String? {
        guard let data = secret.data(using: .utf8),
              let credentials = try? parseCredentials(data: data) else {
            return nil
        }
        return extractIdentity(fromIDToken: credentials.idToken).accountKey
    }

    private func registryAuthSnapshotPath(accountKey: String) -> String {
        "\(accountsDirectoryPath)/\(registryFileKey(for: accountKey)).auth.json"
    }

    private func registryFileKey(for accountKey: String) -> String {
        guard keyNeedsFilenameEncoding(accountKey) else {
            return accountKey
        }
        return Data(accountKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func keyNeedsFilenameEncoding(_ key: String) -> Bool {
        guard !key.isEmpty, key != ".", key != ".." else {
            return true
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return key.unicodeScalars.contains { !allowed.contains($0) }
    }

    private func upsertRegistryAccount(account: Account, secret: String, makeActive: Bool) throws {
        guard let data = secret.data(using: .utf8),
              let credentials = try? parseCredentials(data: data) else {
            return
        }
        let identity = extractIdentity(fromIDToken: credentials.idToken)
        guard let accountKey = identity.accountKey,
              let chatGPTAccountID = identity.chatGPTAccountID,
              let chatGPTUserID = identity.chatGPTUserID else {
            return
        }

        try fileService.createDirectoryIfNeeded(at: accountsDirectoryPath)
        try fileService.writeTextWithBackup(
            secret,
            to: registryAuthSnapshotPath(accountKey: accountKey),
            backupBaseName: "\(registryFileKey(for: accountKey)).auth.json"
        )

        var registry = (try? loadRegistryDocument()) ?? .empty
        let nowSeconds = Int64(Date().timeIntervalSince1970)
        let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let existingIndex = registry.accounts.firstIndex { $0.accountKey == accountKey }
        var entry = existingIndex.map { registry.accounts[$0] } ?? CodexRegistryAccount(accountKey: accountKey)
        let displayName = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityEmail = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        entry.accountKey = accountKey
        entry.authMode = "chatgpt"
        entry.chatGPTAccountID = chatGPTAccountID
        entry.chatGPTUserID = chatGPTUserID
        entry.email = identityEmail
        if !displayName.isEmpty {
            entry.accountName = displayName
        } else if entry.accountName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            entry.accountName = identityEmail
        }
        if entry.alias?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           !displayName.isEmpty,
           displayName.lowercased() != identityEmail {
            entry.alias = displayName
        }
        entry.plan = identity.plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        entry.createdAt = entry.createdAt ?? nowSeconds
        entry.lastUsedAt = makeActive ? nowSeconds : (entry.lastUsedAt ?? nowSeconds)

        if let existingIndex {
            registry.accounts[existingIndex] = entry
        } else {
            registry.accounts.append(entry)
        }

        if makeActive {
            registry.activeAccountKey = accountKey
            registry.activeAccountActivatedAtMs = nowMilliseconds
        }
        try saveRegistryDocument(registry)
    }

    private func removeRegistryAccount(accountKey: String) throws {
        guard fileService.fileExists(at: registryPath) else { return }
        var registry = try loadRegistryDocument()
        registry.accounts.removeAll { $0.accountKey == accountKey }
        if registry.activeAccountKey == accountKey {
            registry.activeAccountKey = registry.accounts.first?.accountKey
            registry.activeAccountActivatedAtMs = registry.activeAccountKey == nil
                ? nil
                : Int64(Date().timeIntervalSince1970 * 1000)
        }
        try saveRegistryDocument(registry)
        try removeStoredSubscription(accountKey: accountKey)
        try fileService.backupItemIfExists(
            at: registryAuthSnapshotPath(accountKey: accountKey),
            backupBaseName: "\(registryFileKey(for: accountKey)).auth.json"
        )
        try fileService.removeItemIfExists(at: registryAuthSnapshotPath(accountKey: accountKey))
    }

    private struct RegistryAccountMetadata {
        let chatGPTAccountID: String?
        let email: String?
        let planName: String?
        let billingCycle: String?
    }

    private func normalizedRegistryKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func loadRegistryAccountMetadata(accountKey: String) -> RegistryAccountMetadata? {
        guard fileService.fileExists(at: registryPath),
              let registry = try? loadRegistryDocument() else {
            return nil
        }

        let key = accountKey.lowercased()
        guard let entry = registry.accounts.first(where: {
            ($0.accountKey?.lowercased() ?? "") == key
        }) else {
            return nil
        }

        let accountID = entry.chatGPTAccountID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = entry.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let planName = entry.resolvedPlan?.trimmingCharacters(in: .whitespacesAndNewlines)
        let billingCycle = entry.extraFields.firstString(keys: ["billing_cycle", "billingCycle", "cycle", "interval"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return RegistryAccountMetadata(
            chatGPTAccountID: (accountID?.isEmpty == false) ? accountID : nil,
            email: (email?.isEmpty == false) ? email : nil,
            planName: (planName?.isEmpty == false) ? planName : nil,
            billingCycle: (billingCycle?.isEmpty == false) ? billingCycle : nil
        )
    }

    private struct SubscriptionCacheMetadata {
        let planName: String?
        let billingCycle: String?
        let accountValidUntil: Date?
        let subscriptionWillRenew: Bool?
        let subscriptionStatus: String?
        let fetchedAt: Date?
    }

    private func loadSubscriptionCacheMetadata(
        accountKey: String?,
        accountID: String?,
        email: String?
    ) -> SubscriptionCacheMetadata? {
        guard fileService.fileExists(at: subscriptionsCachePath),
              let cache = try? loadJSONDictionary(at: subscriptionsCachePath),
              let entry = subscriptionCacheEntry(in: cache, accountKey: accountKey, accountID: accountID, email: email) else {
            return nil
        }

        let planName = firstString(
            in: entry,
            keys: ["plan_name", "planName", "plan", "chatgpt_plan_type", "chatgptPlanType"]
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let billingCycle = firstString(
            in: entry,
            keys: ["billing_cycle", "billingCycle", "cycle", "interval"]
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let subscriptionStatus = firstString(
            in: entry,
            keys: ["subscription_status", "subscriptionStatus", "status"]
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return SubscriptionCacheMetadata(
            planName: (planName?.isEmpty == false) ? planName : nil,
            billingCycle: (billingCycle?.isEmpty == false) ? billingCycle : nil,
            accountValidUntil: findDate(
                in: entry,
                keys: ["account_valid_until", "accountValidUntil", "valid_until", "validUntil", "current_period_end", "currentPeriodEnd"]
            ),
            subscriptionWillRenew: firstBool(in: entry, keys: ["subscription_will_renew", "subscriptionWillRenew", "will_renew", "willRenew"]),
            subscriptionStatus: (subscriptionStatus?.isEmpty == false) ? subscriptionStatus : nil,
            fetchedAt: findDate(
                in: entry,
                keys: ["fetched_at", "fetchedAt", "updated_at", "updatedAt", "updated_at_ms", "updatedAtMs"]
            )
        )
    }

    private func subscriptionCacheEntry(
        in cache: [String: Any],
        accountKey: String?,
        accountID: String?,
        email: String?
    ) -> [String: Any]? {
        let normalizedAccountKey = normalizedRegistryKey(accountKey)?.lowercased()
        let normalizedAccountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let accounts = cache["accounts"] as? [String: Any] {
            for (key, value) in accounts {
                guard let entry = value as? [String: Any] else { continue }
                if key.lowercased() == normalizedAccountKey
                    || key.lowercased() == normalizedAccountID
                    || key.lowercased() == normalizedEmail
                    || subscriptionEntry(entry, matchesAccountKey: normalizedAccountKey, accountID: normalizedAccountID, email: normalizedEmail) {
                    return entry
                }
            }
        }

        if let accounts = cache["accounts"] as? [[String: Any]] {
            return accounts.first {
                subscriptionEntry($0, matchesAccountKey: normalizedAccountKey, accountID: normalizedAccountID, email: normalizedEmail)
            }
        }

        if subscriptionEntry(cache, matchesAccountKey: normalizedAccountKey, accountID: normalizedAccountID, email: normalizedEmail) {
            return cache
        }

        return nil
    }

    private func subscriptionEntry(
        _ entry: [String: Any],
        matchesAccountKey accountKey: String?,
        accountID: String?,
        email: String?
    ) -> Bool {
        let entryAccountKey = firstString(in: entry, keys: ["account_key", "accountKey"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let entryAccountID = firstString(in: entry, keys: ["chatgpt_account_id", "chatgptAccountId", "account_id", "accountId"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let entryEmail = firstString(in: entry, keys: ["email", "account_email", "accountEmail"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return (accountKey?.isEmpty == false && entryAccountKey == accountKey)
            || (accountID?.isEmpty == false && entryAccountID == accountID)
            || (email?.isEmpty == false && entryEmail == email)
    }

    private func storeSubscriptionCache(
        _ snapshot: QuotaSnapshot,
        accountKey: String?,
        accountID: String?,
        email: String?
    ) throws {
        let metadata = SubscriptionCacheMetadata(
            planName: snapshot.planName,
            billingCycle: nil,
            accountValidUntil: snapshot.accountValidUntil,
            subscriptionWillRenew: snapshot.subscriptionWillRenew,
            subscriptionStatus: snapshot.subscriptionStatus,
            fetchedAt: snapshot.updatedAt
        )
        try storeSubscriptionCache(metadata, accountKey: accountKey, accountID: accountID, email: email)
    }

    private func storeSubscriptionCache(
        _ metadata: SubscriptionCacheMetadata,
        accountKey: String?,
        accountID: String?,
        email: String?
    ) throws {
        let planName = metadata.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSubscriptionDetails = planName?.isEmpty == false
            || metadata.accountValidUntil != nil
            || metadata.subscriptionWillRenew != nil
            || metadata.subscriptionStatus?.isEmpty == false
        guard hasSubscriptionDetails else { return }

        let storageKey = normalizedRegistryKey(accountKey)
            ?? accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let storageKey, !storageKey.isEmpty else { return }

        try fileService.createDirectoryIfNeeded(at: accountsDirectoryPath)
        var cache = (try? loadJSONDictionary(at: subscriptionsCachePath)) ?? [
            "schema_version": 1,
            "accounts": [String: Any]()
        ]
        var accounts = cache["accounts"] as? [String: Any] ?? [:]
        var entry = accounts[storageKey] as? [String: Any] ?? [:]
        let nowMilliseconds = Int(Date().timeIntervalSince1970 * 1000)

        entry["account_key"] = normalizedRegistryKey(accountKey)
        entry["chatgpt_account_id"] = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry["email"] = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        entry["plan_name"] = planName
        entry["billing_cycle"] = metadata.billingCycle?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry["account_valid_until"] = metadata.accountValidUntil.map { ISO8601DateFormatter().string(from: $0) }
        entry["subscription_will_renew"] = metadata.subscriptionWillRenew
        entry["subscription_status"] = metadata.subscriptionStatus
        entry["fetched_at"] = Int64((metadata.fetchedAt ?? Date()).timeIntervalSince1970)
        entry["updated_at_ms"] = nowMilliseconds

        accounts[storageKey] = entry
        cache["schema_version"] = cache["schema_version"] ?? 1
        cache["accounts"] = accounts
        cache["updated_at_ms"] = nowMilliseconds

        try writeJSONDictionary(cache, to: subscriptionsCachePath, backup: true)
    }

    private func removeStoredSubscription(accountKey: String) throws {
        guard fileService.fileExists(at: subscriptionsCachePath) else { return }
        var cache = try loadJSONDictionary(at: subscriptionsCachePath)
        guard var accounts = cache["accounts"] as? [String: Any],
              accounts.removeValue(forKey: accountKey) != nil else {
            return
        }
        cache["accounts"] = accounts
        cache["updated_at_ms"] = Int(Date().timeIntervalSince1970 * 1000)
        try writeJSONDictionary(cache, to: subscriptionsCachePath, backup: true)
    }

    private func loadRegistryDocument() throws -> CodexRegistryDocument {
        guard fileService.fileExists(at: registryPath) else {
            return .empty
        }
        let text = try fileService.readText(at: registryPath)
        guard let data = text.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
        }
        return try JSONDecoder().decode(CodexRegistryDocument.self, from: data)
    }

    private func saveRegistryDocument(_ registry: CodexRegistryDocument) throws {
        try fileService.createDirectoryIfNeeded(at: accountsDirectoryPath)
        var normalized = registry
        normalized.schemaVersion = CodexRegistrySchema.currentVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try fileService.writeTextWithBackup(text, to: registryPath, backupBaseName: "registry.json")
    }

    private func updateStoredUsage(
        _ snapshot: QuotaSnapshot,
        accountKey: String?,
        accountID: String?,
        email: String?
    ) throws {
        guard let accountKey = normalizedRegistryKey(accountKey),
              fileService.fileExists(at: registryPath) else {
            return
        }

        var registry = try loadRegistryDocument()
        guard let index = registry.accounts.firstIndex(where: { $0.accountKey == accountKey }) else {
            return
        }

        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedEmail?.isEmpty == false {
            registry.accounts[index].email = normalizedEmail
        }
        if let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            registry.accounts[index].chatGPTAccountID = accountID
        }
        registry.accounts[index].lastUsage = CodexStoredUsageSnapshot(snapshot: snapshot)
        registry.accounts[index].lastUsageAt = Int64(snapshot.updatedAt.timeIntervalSince1970)
        if let planType = registry.accounts[index].lastUsage?.planType,
           planType != "unknown" {
            registry.accounts[index].plan = planType
        }

        try saveRegistryDocument(registry)
    }

    private func loadJSONDictionary(at path: String) throws -> [String: Any] {
        let text = try fileService.readText(at: path)
        guard let data = text.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidCredentials
        }
        return dict
    }

    private func writeJSONDictionary(_ dict: [String: Any], to path: String, backup: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let text = String(data: data, encoding: .utf8) ?? "{}"
        if backup {
            try fileService.writeTextWithBackup(text, to: path, backupBaseName: URL(fileURLWithPath: fileService.expand(path: path)).lastPathComponent)
        } else {
            try fileService.writeText(text, to: path)
        }
    }

    private func quotaCacheKey(
        accountKey: String?,
        accountID: String?,
        fallbackAccountIdentifier: String?
    ) -> String? {
        let raw = [accountKey, accountID, fallbackAccountIdentifier]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let raw else { return nil }

        return Data(raw.lowercased().utf8)
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
        let cached = CachedQuotaSnapshot(
            schemaVersion: 1,
            cachedAt: .init(),
            snapshot: snapshot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cached)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try fileService.writeText(text, to: quotaCachePath(cacheKey: cacheKey))
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

    private func resolveUsageURL(codexHomePath: String?) -> URL {
        let fallback = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let configuredBase: String?
        if let codexHomePath {
            configuredBase = try? String(contentsOfFile: "\(codexHomePath)/config.toml", encoding: .utf8)
                .flatMapChatGPTBaseURL()
        } else if let activeConfig = try? fileService.readText(at: activeConfigPath) {
            configuredBase = activeConfig.flatMapChatGPTBaseURL()
        } else {
            configuredBase = nil
        }

        var base = configuredBase?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "https://chatgpt.com/backend-api"
        while base.hasSuffix("/") {
            base.removeLast()
        }

        guard let baseURL = URL(string: base),
              Self.isTrustedOAuthUsageHost(baseURL.host) else {
            if configuredBase != nil {
                AppLog.refresh.warning("Ignoring non-official Codex chatgpt_base_url for OAuth usage request")
            }
            return fallback
        }

        if (base.hasPrefix("https://chatgpt.com") || base.hasPrefix("https://chat.openai.com")),
           !base.contains("/backend-api") {
            base += "/backend-api"
        }

        let path = base.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        return URL(string: base + path) ?? fallback
    }

    private static func isTrustedOAuthUsageHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
            || host == "chat.openai.com"
            || host.hasSuffix(".chat.openai.com")
    }

    private func resolveSubscriptionURL(codexHomePath: String?) -> URL {
        let usageURL = resolveUsageURL(codexHomePath: codexHomePath)
        let absolute = usageURL.absoluteString
        if absolute.hasSuffix("/wham/usage") {
            return URL(string: String(absolute.dropLast("/wham/usage".count)) + "/subscriptions")
                ?? URL(string: "https://chatgpt.com/backend-api/subscriptions")!
        }
        if absolute.hasSuffix("/api/codex/usage") {
            return URL(string: String(absolute.dropLast("/api/codex/usage".count)) + "/api/codex/subscriptions")
                ?? URL(string: "https://chatgpt.com/backend-api/subscriptions")!
        }
        return URL(string: "https://chatgpt.com/backend-api/subscriptions")!
    }

    private func parseLastRefresh(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func accessTokenExpiresSoon(_ token: String) -> Bool {
        guard let expiresAt = jwtExpirationDate(token) else { return false }
        return expiresAt <= Date().addingTimeInterval(tokenRefreshLeeway)
    }

    private func jwtExpirationDate(_ token: String?) -> Date? {
        guard let exp = parseJWT(token)?["exp"] else { return nil }
        if let number = exp as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let double = exp as? Double {
            return Date(timeIntervalSince1970: double)
        }
        if let int = exp as? Int {
            return Date(timeIntervalSince1970: TimeInterval(int))
        }
        if let text = exp as? String, let double = Double(text) {
            return Date(timeIntervalSince1970: double)
        }
        return nil
    }

    private func findDate(in object: Any, keys: Set<String>) -> Date? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let date = parseFlexibleDate(value) {
                    return date
                }
                if let nested = findDate(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let date = findDate(in: item, keys: keys) {
                    return date
                }
            }
        }
        return nil
    }

    private func parseFlexibleDate(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber {
            let epoch = number.doubleValue
            return epoch > 2_000_000_000
                ? Date(timeIntervalSince1970: epoch / 1000)
                : Date(timeIntervalSince1970: epoch)
        }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let epoch = Double(trimmed) {
                return epoch > 2_000_000_000
                    ? Date(timeIntervalSince1970: epoch / 1000)
                    : Date(timeIntervalSince1970: epoch)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: trimmed) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: trimmed)
        }
        return nil
    }

    private func stringValue(in dictionary: [String: Any]?, snakeKey: String, camelKey: String) -> String? {
        guard let dictionary else { return nil }
        if let value = dictionary[snakeKey] as? String, !value.isEmpty {
            return value
        }
        if let value = dictionary[camelKey] as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    private func extractErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let code = error["code"] as? String {
            return code
        }
        if let error = json["error"] as? String {
            return error
        }
        return json["code"] as? String
    }

#if DEBUG
    func parseRateLimitPayloadForTesting(
        _ payload: Any,
        accountIdentifier: String? = "fixture@example.com",
        planName: String? = nil,
        accountValidUntil: Date? = nil,
        subscriptionWillRenew: Bool? = nil,
        subscriptionStatus: String? = nil
    ) -> QuotaSnapshot? {
        parseCodexRateLimitPayload(
            payload,
            fallbackAccountIdentifier: accountIdentifier,
            fallbackPlanName: planName,
            fallbackAccountValidUntil: accountValidUntil,
            fallbackSubscriptionWillRenew: subscriptionWillRenew,
            fallbackSubscriptionStatus: subscriptionStatus
        )
    }
#endif

    private func parseCodexRateLimitPayload(
        _ payload: Any,
        fallbackAccountIdentifier: String?,
        fallbackPlanName: String?,
        fallbackAccountValidUntil: Date?,
        fallbackSubscriptionWillRenew: Bool?,
        fallbackSubscriptionStatus: String?
    ) -> QuotaSnapshot? {
        guard let dict = payload as? [String: Any] else { return nil }
        guard let rateLimit = (dict["rate_limit"] as? [String: Any])
            ?? (dict["rateLimit"] as? [String: Any]) else { return nil }

        let primary = parseCodexWindow(
            (rateLimit["primary_window"] as? [String: Any])
                ?? (rateLimit["primaryWindow"] as? [String: Any])
        )
        let secondary = parseCodexWindow(
            (rateLimit["secondary_window"] as? [String: Any])
                ?? (rateLimit["secondaryWindow"] as? [String: Any])
        )
        let credits = dict["credits"] as? [String: Any]
        let creditsRemaining = credits.flatMap {
            firstDouble(in: $0, keys: ["balance", "remaining", "available", "total_available", "totalAvailable"])
        }
        let creditsTotal = credits.flatMap { creditDict -> Double? in
            if let total = firstDouble(in: creditDict, keys: ["total", "limit", "granted", "total_granted", "totalGranted"]) {
                return total
            }
            if let remaining = creditsRemaining,
               let used = firstDouble(in: creditDict, keys: ["used", "spent", "total_used", "totalUsed"]) {
                return remaining + used
            }
            return nil
        }
        let planName = normalizedPlanName(
            extractPlanName(from: dict) ?? fallbackPlanName,
            cycle: extractBillingCycle(from: dict) ?? fallbackPlanName
        )
        let allowed = (rateLimit["allowed"] as? Bool)
        let limitReached = (rateLimit["limit_reached"] as? Bool)
            ?? (rateLimit["limitReached"] as? Bool)

        let snapshot = QuotaSnapshot(
            source: "Codex OAuth",
            accountIdentifier: fallbackAccountIdentifier,
            planName: planName,
            primary: primary,
            secondary: secondary,
            creditsRemaining: creditsRemaining,
            creditsTotal: creditsTotal,
            updatedAt: .init(),
            periodEnd: nil,
            accountValidUntil: paidAccountValidUntil(planName, fallbackAccountValidUntil),
            subscriptionWillRenew: fallbackSubscriptionWillRenew,
            subscriptionStatus: fallbackSubscriptionStatus,
            isQuotaBlocked: (limitReached == true) || (allowed == false),
            note: (primary == nil && secondary == nil && creditsRemaining == nil) ? "接口返回成功，但额度字段为空" : nil
        )
        return snapshot
    }

    private func parseCodexWindow(_ dict: [String: Any]?) -> QuotaWindow? {
        guard let dict else { return nil }

        guard var usedPercent = firstDouble(in: dict, keys: ["used_percent", "usedPercent"]) else { return nil }
        if usedPercent > 0, usedPercent < 1 {
            usedPercent *= 100
        }
        usedPercent = min(max(usedPercent, 0), 100)

        let windowSeconds = firstInt(in: dict, keys: ["limit_window_seconds", "limitWindowSeconds", "reset_after_seconds", "resetAfterSeconds"])
            ?? firstInt(in: dict, keys: ["window_minutes", "windowMinutes"]).map { $0 * 60 }
            ?? 0
        let resetAt = parseFlexibleDate(firstValue(in: dict, keys: ["reset_at", "resetAt", "resets_at", "resetsAt"]))
            ?? firstDouble(in: dict, keys: ["reset_after_seconds", "resetAfterSeconds"]).map {
                Date().addingTimeInterval($0)
            }

        return QuotaWindow(
            label: labelForWindow(seconds: windowSeconds),
            used: usedPercent,
            limit: 100,
            resetAt: resetAt
        )
    }

    private func firstValue(in dict: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dict[key] {
                return value
            }
        }
        return nil
    }

    private func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let text = value as? String {
                return text
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private func firstBool(in dict: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let bool = value as? Bool {
                return bool
            }
            if let number = value as? NSNumber {
                return number.boolValue
            }
            if let text = value as? String {
                switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "1":
                    return true
                case "false", "no", "0":
                    return false
                default:
                    continue
                }
            }
        }
        return nil
    }

    private func firstDouble(in dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let number = value as? NSNumber { return number.doubleValue }
            if let number = value as? Double { return number }
            if let number = value as? Int { return Double(number) }
            if let text = value as? String, let number = parseLooseDouble(text) { return number }
        }
        return nil
    }

    private func parseLooseDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed) {
            return number
        }

        let cleaned = trimmed
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    private func firstInt(in dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let number = value as? NSNumber { return number.intValue }
            if let number = value as? Int { return number }
            if let number = value as? Double { return Int(number) }
            if let text = value as? String, let number = Int(text) { return number }
        }
        return nil
    }

    private func labelForWindow(seconds: Int) -> String {
        switch seconds {
        case 18_000:
            return "5h"
        case 604_800:
            return "Weekly"
        case 2_592_000:
            return "Monthly"
        default:
            return "Usage"
        }
    }

    private func fetchCreditGrants(apiKey: String, note: String?) async throws -> QuotaSnapshot {
        let url = URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await dataWithRetry(for: request, operation: "OpenAI credit_grants 查询")

        let payload = try JSONSerialization.jsonObject(with: data)
        guard let dict = payload as? [String: Any] else {
            throw ProviderError.network("OpenAI credit_grants 返回格式异常")
        }

        let totalGranted = JSONObjectPath.findDouble(in: dict, keys: ["total_granted", "grant_amount"])
        let totalUsed = JSONObjectPath.findDouble(in: dict, keys: ["total_used", "used_amount"])
        let totalAvailable = JSONObjectPath.findDouble(in: dict, keys: ["total_available", "available_amount"])

        let resolvedTotal: Double?
        let resolvedRemaining: Double?

        if let totalGranted {
            resolvedTotal = totalGranted
            if let totalAvailable {
                resolvedRemaining = totalAvailable
            } else if let totalUsed {
                resolvedRemaining = max(totalGranted - totalUsed, 0)
            } else {
                resolvedRemaining = nil
            }
        } else if let totalAvailable, let totalUsed {
            resolvedTotal = totalAvailable + totalUsed
            resolvedRemaining = totalAvailable
        } else {
            resolvedTotal = nil
            resolvedRemaining = nil
        }

        return QuotaSnapshot(
            source: "OpenAI API Key",
            planName: "API Key",
            primary: nil,
            secondary: nil,
            creditsRemaining: resolvedRemaining,
            creditsTotal: resolvedTotal,
            updatedAt: .init(),
            note: note
        )
    }
}

private struct CodexUsageIdentity {
    let email: String?
    let userID: String?
    let accountID: String?
}

private struct CodexDeviceAuthPrompt: Sendable {
    let url: URL
    let code: String
}

private final class CodexLoginFallbackURLScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var didFindURL = false

    func append(_ data: Data) -> URL? {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        guard !didFindURL else { return nil }
        buffer += text
        if buffer.count > 8_000 {
            buffer = String(buffer.suffix(8_000))
        }

        guard Self.containsBrowserOpenFailure(in: buffer),
              let url = Self.extractFirstExternalLoginURL(from: buffer) else {
            return nil
        }

        didFindURL = true
        return url
    }

    private static func containsBrowserOpenFailure(in text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("failed to open browser")
            || normalized.contains("failed to open login url")
            || normalized.contains("failed to open browser for login url")
    }

    private static func extractFirstExternalLoginURL(from text: String) -> URL? {
        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let trailingPunctuation = CharacterSet(charactersIn: ".,;:)]}")

        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let rawURL = String(text[matchRange]).trimmingCharacters(in: trailingPunctuation)
            guard let url = URL(string: rawURL),
                  isExternalLoginURL(url) else {
                continue
            }
            return url
        }

        return nil
    }

    private static func isExternalLoginURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }

        if host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host.hasSuffix(".localhost") {
            return false
        }

        return host == "auth.openai.com"
            || host.hasSuffix(".auth.openai.com")
            || host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
            || host == "openai.com"
            || host.hasSuffix(".openai.com")
    }
}

private final class CodexDeviceAuthPromptScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var didPresent = false

    func append(_ data: Data) -> CodexDeviceAuthPrompt? {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        guard !didPresent else { return nil }
        buffer += text.strippingANSIControlSequences()
        if buffer.count > 8_000 {
            buffer = String(buffer.suffix(8_000))
        }

        guard let url = Self.extractDeviceAuthURL(from: buffer),
              let code = Self.extractDeviceCode(from: buffer) else {
            return nil
        }

        didPresent = true
        return CodexDeviceAuthPrompt(url: url, code: code)
    }

    private static func extractDeviceAuthURL(from text: String) -> URL? {
        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let trailingPunctuation = CharacterSet(charactersIn: ".,;:)]}")

        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let rawURL = String(text[matchRange]).trimmingCharacters(in: trailingPunctuation)
            guard let url = URL(string: rawURL),
                  let host = url.host?.lowercased(),
                  host == "auth.openai.com" || host.hasSuffix(".auth.openai.com") else {
                continue
            }
            return url
        }

        return nil
    }

    private static func extractDeviceCode(from text: String) -> String? {
        let pattern = #"\b[A-Z0-9]{4,6}-[A-Z0-9]{4,8}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }
}

extension CodexProvider {
    private struct TokenIdentity {
        let email: String?
        let plan: String?
        let cycle: String?
        let chatGPTAccountID: String?
        let chatGPTUserID: String?
        let accountValidUntil: Date?
        let subscriptionWillRenew: Bool?
        let subscriptionStatus: String?

        var accountKey: String? {
            guard let chatGPTUserID, let chatGPTAccountID else { return nil }
            return "\(chatGPTUserID)::\(chatGPTAccountID)"
        }
    }

    private func extractEmail(fromIDToken token: String?) -> String? {
        extractIdentity(fromIDToken: token).email
    }

    private func validateCodexUsageIdentity(
        in payload: Any,
        expectedAccountKey: String?,
        expectedEmail: String?
    ) throws {
        let actual = extractUsageIdentity(from: payload)
        let expectedUserID = expectedAccountKey?
            .split(separator: "::", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpectedEmail = expectedEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let expectedUserID,
           !expectedUserID.isEmpty,
           let actualUserID = actual.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !actualUserID.isEmpty,
           actualUserID != expectedUserID {
            throw ProviderError.network("Codex 返回账号与当前账号不一致，请重新登录该账号")
        }

        if let normalizedExpectedEmail,
           !normalizedExpectedEmail.isEmpty,
           let actualEmail = actual.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !actualEmail.isEmpty,
           actualEmail != normalizedExpectedEmail {
            throw ProviderError.network("Codex 返回账号与当前账号不一致，请重新登录该账号")
        }
    }

    private func extractUsageIdentity(from payload: Any) -> CodexUsageIdentity {
        let email = JSONObjectPath.findString(in: payload, keys: ["email", "account_email", "accountEmail"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let userID = JSONObjectPath.findString(in: payload, keys: ["user_id", "userId", "chatgpt_user_id", "chatgptUserId"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = JSONObjectPath.findString(in: payload, keys: ["account_id", "accountId", "chatgpt_account_id", "chatgptAccountId"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexUsageIdentity(
            email: (email?.isEmpty == false) ? email : nil,
            userID: (userID?.isEmpty == false) ? userID : nil,
            accountID: (accountID?.isEmpty == false) ? accountID : nil
        )
    }

    private func extractIdentity(fromIDToken token: String?) -> TokenIdentity {
        guard let dict = parseJWT(token) else {
            return TokenIdentity(
                email: nil,
                plan: nil,
                cycle: nil,
                chatGPTAccountID: nil,
                chatGPTUserID: nil,
                accountValidUntil: nil,
                subscriptionWillRenew: nil,
                subscriptionStatus: nil
            )
        }

        let profile = dict["https://api.openai.com/profile"] as? [String: Any]
        let auth = dict["https://api.openai.com/auth"] as? [String: Any]

        let email = ((dict["email"] as? String) ?? (profile?["email"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let plan = extractPlanName(from: dict)
        let cycle = extractBillingCycle(from: dict)
        let chatGPTAccountID = stringValue(in: auth, snakeKey: "chatgpt_account_id", camelKey: "chatgptAccountId")
        let chatGPTUserID = stringValue(in: auth, snakeKey: "chatgpt_user_id", camelKey: "chatgptUserId")
        let subscriptionStatus = extractSubscriptionStatus(from: dict)

        return TokenIdentity(
            email: email?.contains("@") == true ? email : nil,
            plan: plan,
            cycle: cycle,
            chatGPTAccountID: chatGPTAccountID,
            chatGPTUserID: chatGPTUserID,
            accountValidUntil: extractSubscriptionActiveUntil(from: dict),
            subscriptionWillRenew: extractSubscriptionWillRenew(from: dict, subscriptionStatus: subscriptionStatus),
            subscriptionStatus: subscriptionStatus
        )
    }

    private func extractSubscriptionActiveUntil(from object: Any) -> Date? {
        findDate(
            in: object,
            keys: [
                "chatgpt_subscription_active_until",
                "chatgptSubscriptionActiveUntil",
                "subscription_active_until",
                "subscriptionActiveUntil",
                "current_period_end",
                "currentPeriodEnd",
                "next_billing_date",
                "nextBillingDate",
                "renewal_date",
                "renewalDate",
                "expires_at",
                "expiresAt",
                "active_until",
                "activeUntil"
            ]
        )
    }

    private func extractSubscriptionWillRenew(from object: Any, subscriptionStatus: String?) -> Bool? {
        if let cancelAtPeriodEnd = JSONObjectPath.findBool(
            in: object,
            keys: ["cancel_at_period_end", "cancelAtPeriodEnd"]
        ) {
            return !cancelAtPeriodEnd
        }
        if let willRenew = JSONObjectPath.findBool(
            in: object,
            keys: ["will_renew", "willRenew", "auto_renew", "autoRenew", "renews", "renewing"]
        ) {
            return willRenew
        }
        return inferSubscriptionWillRenew(from: subscriptionStatus)
    }

    private func extractSubscriptionStatus(from object: Any) -> String? {
        JSONObjectPath.findString(
            in: object,
            keys: [
                "subscription_status",
                "subscriptionStatus",
                "chatgpt_subscription_status",
                "chatgptSubscriptionStatus",
                "status"
            ]
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    }

    private func inferSubscriptionWillRenew(from status: String?) -> Bool? {
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !status.isEmpty else {
            return nil
        }
        switch status {
        case "active", "trialing", "paid":
            return true
        case "canceled", "cancelled", "expired", "incomplete_expired", "unpaid", "past_due":
            return false
        default:
            return nil
        }
    }

    private func paidAccountValidUntil(_ planName: String?, _ date: Date?) -> Date? {
        guard let date,
              let planName = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !planName.isEmpty,
              !planName.contains("free"),
              !planName.contains("hobby"),
              !planName.contains("api key"),
              planName != "api" else {
            return nil
        }

        let paidMarkers = ["plus", "pro", "team", "business", "enterprise", "ultra", "max", "unlimited"]
        return paidMarkers.contains { planName.contains($0) } ? date : nil
    }

    private func extractPlanName(from object: Any) -> String? {
        JSONObjectPath.findString(
            in: object,
            keys: [
                "chatgpt_plan_type",
                "chatgptPlanType",
                "plan_type",
                "planType",
                "plan_name",
                "planName",
                "plan",
                "account_plan_type",
                "accountPlanType",
                "account_plan",
                "accountPlan",
                "subscription_plan_type",
                "subscriptionPlanType",
                "subscription_plan",
                "subscriptionPlan",
                "billing_plan",
                "billingPlan",
                "membership_type",
                "membershipType",
                "product",
                "product_name",
                "productName",
                "sku",
                "sku_name",
                "skuName",
                "tier",
                "account_tier",
                "accountTier"
            ]
        )
    }

    private func extractBillingCycle(from object: Any) -> String? {
        if let cycle = JSONObjectPath.findString(
            in: object,
            keys: [
                "billing_period",
                "billingPeriod",
                "billing_interval",
                "billingInterval",
                "billing_cycle",
                "billingCycle",
                "plan_interval",
                "planInterval",
                "plan_period",
                "planPeriod",
                "subscription_interval",
                "subscriptionInterval",
                "subscription_period",
                "subscriptionPeriod",
                "subscription_billing_cycle",
                "subscriptionBillingCycle",
                "renewal_interval",
                "renewalInterval",
                "renewal_period",
                "renewalPeriod",
                "payment_interval",
                "paymentInterval",
                "recurring_interval",
                "recurringInterval",
                "interval_unit",
                "intervalUnit",
                "interval"
            ]
        ) {
            return cycle
        }

        if JSONObjectPath.findBool(in: object, keys: ["is_annual", "isAnnual", "is_yearly", "isYearly", "annual", "yearly"]) == true {
            return "annual"
        }
        if JSONObjectPath.findBool(in: object, keys: ["is_monthly", "isMonthly", "monthly", "is_month_to_month", "isMonthToMonth"]) == true {
            return "monthly"
        }

        return nil
    }

    private func normalizedPlanName(_ raw: String?, cycle rawCycle: String? = nil) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()

        let base: String
        if lower.contains("enterprise") {
            base = "Enterprise"
        } else if lower.contains("team") || lower.contains("business") {
            base = "Team"
        } else if lower.contains("pro") {
            base = "Pro"
        } else if lower.contains("plus") {
            base = "Plus"
        } else if lower.contains("free") {
            base = "Free"
        } else {
            base = raw
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }

        if base.lowercased().contains("free") || base.lowercased() == "api" || base.lowercased().contains("api key") {
            return base
        }

        let cycleSource = [lower, rawCycle?.lowercased()].compactMap { $0 }.joined(separator: " ")
        if cycleSource.contains("annual")
            || cycleSource.contains("annually")
            || cycleSource.contains("yearly")
            || cycleSource.contains("year")
            || cycleSource.contains("p1y")
            || cycleSource.contains(" yr")
            || cycleSource.hasSuffix("yr")
            || cycleSource.contains("12 month")
            || cycleSource.contains("12-month") {
            return "\(base) Annual"
        }
        if cycleSource.contains("monthly")
            || cycleSource.contains("month")
            || cycleSource.contains("p1m")
            || cycleSource.contains(" mo")
            || cycleSource.hasSuffix("mo") {
            return "\(base) Monthly"
        }
        return base
    }

    private func parseJWT(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }
}

private extension String {
    func strippingANSIControlSequences() -> String {
        let escape = "\u{001B}"
        return replacingOccurrences(
            of: "\(escape)\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    func singleLineCondensed(maxLength: Int) -> String {
        let condensed = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard condensed.count > maxLength else { return condensed }
        return "\(condensed.prefix(maxLength))..."
    }

    func upsertingTopLevelTOMLString(key: String, value: String) -> String {
        let assignment = "\(key) = \"\(value)\""
        var lines = split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var firstTableIndex: Int?
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                firstTableIndex = index
                break
            }
            guard trimmed.isEmpty == false,
                  trimmed.hasPrefix("#") == false else {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key {
                lines[index] = assignment
                return lines.joined(separator: "\n").ensuringTrailingNewline()
            }
        }

        if lines.isEmpty {
            return "\(assignment)\n"
        }

        if let firstTableIndex {
            lines.insert(assignment, at: firstTableIndex)
            if firstTableIndex + 1 < lines.count,
               lines[firstTableIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                lines.insert("", at: firstTableIndex + 1)
            }
            return lines.joined(separator: "\n").ensuringTrailingNewline()
        }

        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("")
        }
        lines.append(assignment)
        return lines.joined(separator: "\n").ensuringTrailingNewline()
    }

    func ensuringTrailingNewline() -> String {
        hasSuffix("\n") ? self : "\(self)\n"
    }

    func flatMapChatGPTBaseURL() -> String? {
        for rawLine in split(whereSeparator: \.isNewline) {
            let uncommented = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
            let trimmed = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url" else { continue }

            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }

        return nil
    }
}

private enum JSONObjectPath {
    static func findString(in object: Any, keys: Set<String>) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let text = asString(value) {
                    return text
                }
                if let nested = findString(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let text = findString(in: item, keys: keys) {
                    return text
                }
            }
        }
        return nil
    }

    static func findDouble(in object: Any, keys: Set<String>) -> Double? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let number = asDouble(value) {
                    return number
                }
                if let nested = findDouble(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let number = findDouble(in: item, keys: keys) {
                    return number
                }
            }
        }
        return nil
    }

    static func findBool(in object: Any, keys: Set<String>) -> Bool? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let bool = asBool(value) {
                    return bool
                }
                if let nested = findBool(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let bool = findBool(in: item, keys: keys) {
                    return bool
                }
            }
        }
        return nil
    }

    private static func asString(_ value: Any) -> String? {
        if let text = value as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func asBool(_ value: Any) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func asDouble(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

enum UsageWindowExtractor {
    static func extract(from payload: Any) -> [QuotaWindow] {
        var results: [QuotaWindow] = []
        walk(payload, keyHint: nil, collector: &results)

        var seen = Set<String>()
        return results.filter { window in
            let key = "\(window.label)-\(window.limit)-\(window.used)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private static func walk(_ node: Any, keyHint: String?, collector: inout [QuotaWindow]) {
        if let dict = node as? [String: Any] {
            if let window = parseWindow(from: dict, keyHint: keyHint) {
                collector.append(window)
            }
            for (key, value) in dict {
                walk(value, keyHint: key, collector: &collector)
            }
        } else if let array = node as? [Any] {
            for value in array {
                walk(value, keyHint: keyHint, collector: &collector)
            }
        }
    }

    private static func parseWindow(from dict: [String: Any], keyHint: String?) -> QuotaWindow? {
        let used = firstDouble(in: dict, keys: ["used", "usage", "used_amount", "consumed", "spent", "used_usd", "value_used"])
        let remaining = firstDouble(in: dict, keys: ["remaining", "left", "available", "remaining_amount", "value_remaining"])
        let limit = firstDouble(in: dict, keys: ["limit", "max", "quota", "total", "capacity", "value_limit"])

        let resolvedLimit: Double
        let resolvedUsed: Double

        if let limit, let used {
            resolvedLimit = limit
            resolvedUsed = used
        } else if let limit, let remaining {
            resolvedLimit = limit
            resolvedUsed = max(limit - remaining, 0)
        } else if let used, let remaining {
            resolvedLimit = used + remaining
            resolvedUsed = used
        } else {
            return nil
        }

        guard resolvedLimit > 0 else {
            return nil
        }

        let label = normalizedLabel(from: keyHint)
        let resetAt = parseDate(value: firstValue(in: dict, keys: ["reset_at", "resets_at", "resetAt", "next_reset_at", "end_at", "ends_at"]))

        return QuotaWindow(
            label: label,
            used: resolvedUsed,
            limit: resolvedLimit,
            resetAt: resetAt
        )
    }

    private static func normalizedLabel(from keyHint: String?) -> String {
        guard let hint = keyHint?.lowercased() else {
            return "Usage"
        }

        if hint.contains("five") || hint.contains("5h") {
            return "5h"
        }
        if hint.contains("week") || hint.contains("seven") {
            return "Weekly"
        }
        if hint.contains("month") {
            return "Monthly"
        }
        return keyHint ?? "Usage"
    }

    private static func firstDouble(in dict: [String: Any], keys: Set<String>) -> Double? {
        for (key, value) in dict where keys.contains(key) {
            if let number = asDouble(value) {
                return number
            }
        }
        return nil
    }

    private static func firstValue(in dict: [String: Any], keys: Set<String>) -> Any? {
        for (key, value) in dict where keys.contains(key) {
            return value
        }
        return nil
    }

    private static func asDouble(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func parseDate(value: Any?) -> Date? {
        guard let value else { return nil }

        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return raw > 2_000_000_000 ? Date(timeIntervalSince1970: raw / 1000) : Date(timeIntervalSince1970: raw)
        }

        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) {
                return date
            }
            if let raw = Double(text) {
                return raw > 2_000_000_000 ? Date(timeIntervalSince1970: raw / 1000) : Date(timeIntervalSince1970: raw)
            }
        }

        return nil
    }
}
