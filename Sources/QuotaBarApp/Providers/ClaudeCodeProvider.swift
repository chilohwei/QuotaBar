import CryptoKit
import Foundation

struct ClaudeCodeProvider: Provider {
    let tool: ToolKind = .claudeCode

    private let fileService = FileService()

    private struct ClaudeCodeCredentials: Codable {
        let loggedIn: Bool
        let authMethod: String?
        let apiProvider: String?
        let userID: String?
        let claudeExecutablePath: String?
        let keychainCredentials: String?
        let authStatusJSON: String?
        let claudeSettingsJSON: String?
        let claudeJSON: String?
        let claudeCredentialsJSON: String?
        let claudeAuthJSON: String?
    }

    func importCurrentCredentials() async throws -> String {
        let credentials = try await readClaudeCodeCredentials()
        guard credentials.loggedIn else {
            throw ProviderError.unsupported(claudeLoginRequiredMessage)
        }
        try installQuotaBarStatusLine()
        return try encodeCredentials(credentials)
    }

    func authenticateViaBrowser() async throws -> String {
        do {
            let previous = try? await readClaudeCodeCredentials()
            try await runClaudeAuthLogin(timeout: 300)
            let credentials = try await readClaudeCodeCredentials()
            guard credentials.loggedIn else {
                throw ProviderError.unsupported(claudeLoginRequiredMessage)
            }
            if shouldClearStatusLineSnapshot(previous: previous, next: credentials) {
                try? fileService.removeItemIfExists(at: AppPaths.claudeCodeStatusFile.path)
            }
            try installQuotaBarStatusLine()
            return try encodeCredentials(credentials)
        } catch {
            openClaudeCodePage()
            if case ProviderError.unsupported = error {
                throw error
            }
            throw ProviderError.unsupported(claudeLoginRequiredMessage)
        }
    }

    func prepareAccount(_ account: Account, secret: String) async throws -> Account {
        var updated = account
        updated.settings.identityKey = accountIdentity(from: secret) ?? account.settings.identityKey
        try installQuotaBarStatusLine()
        return updated
    }

    func activate(account: Account, secret: String) async throws {
        let stored = try parseCredentials(secret)
        let previous = try? await readClaudeCodeCredentials()
        var replacedCredentials = false
        if hasRestorableClaudeArtifacts(stored) {
            try restoreClaudeArtifacts(from: stored)
            replacedCredentials = true
        }
        if let keychainCredentials = stored.keychainCredentials?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainCredentials.isEmpty {
            try writeClaudeCodeKeychainCredentials(keychainCredentials)
            try writeClaudeUserID(stored.userID)
            replacedCredentials = true
        }
        let latest = try await readClaudeCodeCredentials()
        guard latest.loggedIn,
              claudeCredentialsRepresentSameAccount(latest, stored) else {
            throw ProviderError.unsupported("Claude Code 切换后读取到的账号不一致；请在 Claude Code 中切到该账号后重新添加。")
        }
        if replacedCredentials, shouldClearStatusLineSnapshot(previous: previous, next: stored) {
            try? fileService.removeItemIfExists(at: AppPaths.claudeCodeStatusFile.path)
        }
        try installQuotaBarStatusLine()
    }

    func fetchQuota(secret: String) async throws -> QuotaSnapshot {
        try await fetchQuota(account: Account(tool: .claudeCode, name: "Claude Code"), secret: secret)
    }

    func fetchQuota(account: Account, secret: String) async throws -> QuotaSnapshot {
        let storedCredentials = try parseCredentials(secret)
        let liveStatus = try? loadStatusLineSnapshot()
        let credentials: ClaudeCodeCredentials
        let status: [String: Any]?
        if let latest = try? await readClaudeCodeCredentials(),
           claudeCredentialsRepresentSameAccount(latest, storedCredentials) {
            credentials = mergeCredentials(preferred: latest, fallback: storedCredentials)
            status = shouldUseStatusLineSnapshot(liveStatus, settingsJSON: latest.claudeSettingsJSON)
                ? liveStatus
                : nil
        } else {
            credentials = storedCredentials
            status = nil
        }

        return makeQuotaSnapshot(status: status, credentials: credentials)
    }

    func recoverSecret(for account: Account) async throws -> String? {
        let credentials = try await readClaudeCodeCredentials()
        guard credentials.loggedIn else { return nil }
        let merged = mergeCredentials(preferred: credentials, fallback: credentials)
        let encoded = try encodeCredentials(merged)
        guard let expected = account.settings.identityKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else {
            return encoded
        }
        if accountIdentity(from: encoded) == expected {
            return encoded
        }
        if legacyIdentity(from: merged) == normalizeIdentityKey(expected),
           merged.userID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return encoded
        }
        return nil
    }

    func refreshSecretIfNeeded(_ secret: String) async throws -> String {
        let stored = try parseCredentials(secret)
        guard let latest = try? await readClaudeCodeCredentials(),
              latest.loggedIn,
              claudeCredentialsRepresentSameAccount(latest, stored) else {
            return secret
        }
        let merged = mergeCredentials(preferred: latest, fallback: stored)
        let encoded = try encodeCredentials(merged)
        return encoded == secret ? secret : encoded
    }

    func accountIdentity(from secret: String) -> String? {
        accountIdentityAliases(from: secret).first
    }

    func accountIdentityAliases(from secret: String) -> [String] {
        guard let credentials = try? parseCredentials(secret) else { return [] }
        var aliases: [String] = []
        if let userID = credentials.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            aliases.append("claude-code:user:\(userID)")
        }
        if let keychainCredentials = credentials.keychainCredentials?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainCredentials.isEmpty {
            aliases.append("claude-code:keychain:\(stableCredentialFingerprint(keychainCredentials))")
        }
        let method = credentials.authMethod?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        aliases.append("claude-code:\(method):\(provider)")
        return uniqueIdentityAliases(aliases)
    }

    func suggestAccountName(from secret: String) -> String? {
        guard let credentials = try? parseCredentials(secret) else { return "Claude Code" }
        if let email = readableEmail(from: credentials) {
            return email
        }
        if let userID = credentials.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            return "Claude \(String(userID.suffix(8)))"
        }
        if let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty,
           !isFirstPartyClaudeProvider(provider) {
            return "Claude Code (\(displayProviderName(from: provider)))"
        }
        return "Claude Code"
    }

    private func readClaudeCodeCredentials() async throws -> ClaudeCodeCredentials {
        guard let executable = claudeExecutableURL() else {
            throw ProviderError.unsupported("未找到 Claude Code CLI。请先安装 claude，或确认 claude 命令可用。")
        }
        let output = try await runProcess(executable: executable, arguments: ["auth", "status"], timeout: 10)
        guard let data = output.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidCredentials
        }
        let loggedIn = object["loggedIn"] as? Bool ?? false
        return ClaudeCodeCredentials(
            loggedIn: loggedIn,
            authMethod: object["authMethod"] as? String,
            apiProvider: object["apiProvider"] as? String,
            userID: readClaudeUserID(),
            claudeExecutablePath: executable.path,
            keychainCredentials: try? readClaudeCodeKeychainCredentials(),
            authStatusJSON: output,
            claudeSettingsJSON: readTextIfExists(claudeSettingsURL()),
            claudeJSON: readTextIfExists(claudeJSONURL()),
            claudeCredentialsJSON: readTextIfExists(claudeCredentialsURL()),
            claudeAuthJSON: readTextIfExists(claudeAuthURL())
        )
    }

    private var claudeLoginRequiredMessage: String {
        "Claude Code 尚未登录。为避免在 Launchpad 里创建 Claude Code URL Handler，QuotaBar 不会代替 Claude Code 执行 OAuth 登录；请先在 Claude Code 自身完成登录，然后回到 QuotaBar 点击添加。"
    }

    private func openClaudeCodePage() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["https://claude.ai/code"]
        try? process.run()
    }

    private func runClaudeAuthLogin(timeout: TimeInterval) async throws {
        guard let executable = claudeExecutableURL() else {
            throw ProviderError.unsupported("未找到 Claude Code CLI。请先安装 claude，或确认 claude 命令可用。")
        }
        _ = try await runProcess(
            executable: executable,
            arguments: ["auth", "login", "--claudeai"],
            timeout: timeout
        )
    }

    private func claudeExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
        let fixedCandidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude"
        ].map { URL(fileURLWithPath: $0) }

        return (pathCandidates + fixedCandidates).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func readClaudeUserID() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
            .path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userID = object["userID"] as? String else {
            return nil
        }
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeClaudeUserID(_ userID: String?) throws {
        guard let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userID.isEmpty else {
            return
        }

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        let object: [String: Any]
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var updated = existing
            updated["userID"] = userID
            object = updated
        } else {
            object = ["userID": userID]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func hasRestorableClaudeArtifacts(_ credentials: ClaudeCodeCredentials) -> Bool {
        [
            credentials.claudeCredentialsJSON,
            credentials.claudeAuthJSON
        ].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private func restoreClaudeArtifacts(from credentials: ClaudeCodeCredentials) throws {
        if let claudeJSON = credentials.claudeJSON,
           !claudeJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try writeText(claudeJSON, to: claudeJSONURL(), permissions: nil)
        } else {
            try writeClaudeUserID(credentials.userID)
        }

        if let claudeCredentialsJSON = credentials.claudeCredentialsJSON,
           !claudeCredentialsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try writeText(claudeCredentialsJSON, to: claudeCredentialsURL(), permissions: 0o600)
        }

        if let claudeAuthJSON = credentials.claudeAuthJSON,
           !claudeAuthJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try writeText(claudeAuthJSON, to: claudeAuthURL(), permissions: 0o600)
        }
    }

    private func claudeJSONURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    private func claudeCredentialsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
    }

    private func claudeSettingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private func claudeAuthURL() -> URL {
        claudeConfigDirectoryURL().appendingPathComponent("auth.json")
    }

    private func claudeConfigDirectoryURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        if let xdgConfig = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgConfig.isEmpty {
            return URL(fileURLWithPath: xdgConfig).appendingPathComponent("claude-code", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("claude-code", isDirectory: true)
    }

    private func readTextIfExists(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func writeText(_ text: String, to url: URL, permissions: Int?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    private func readClaudeCodeKeychainCredentials() throws -> String? {
        try readKeychainPassword(service: "Claude Code-credentials")
    }

    private func writeClaudeCodeKeychainCredentials(_ credentials: String) throws {
        let account = NSUserName()
        _ = try? runSecurity(arguments: [
            "delete-generic-password",
            "-s",
            "Claude Code-credentials",
            "-a",
            account
        ], capturePassword: false)
        _ = try runSecurity(arguments: [
            "add-generic-password",
            "-s",
            "Claude Code-credentials",
            "-a",
            account,
            "-w",
            credentials
        ], capturePassword: false)
    }

    private func readKeychainPassword(service: String) throws -> String? {
        let value = try runSecurity(arguments: [
            "find-generic-password",
            "-s",
            service,
            "-w"
        ], capturePassword: true)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runSecurity(arguments: [String], capturePassword: Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return output
        }

        if capturePassword {
            return ""
        }
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw ProviderError.network(error?.isEmpty == false ? error! : "写入 Claude Code Keychain 失败")
    }

    private func readableIdentity(from credentials: ClaudeCodeCredentials) -> String? {
        if let email = readableEmail(from: credentials) {
            return email
        }
        guard let userID = credentials.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userID.isEmpty else {
            return nil
        }
        return "Claude \(String(userID.suffix(8)))"
    }

    private func readableEmail(from credentials: ClaudeCodeCredentials) -> String? {
        [
            credentials.authStatusJSON,
            credentials.claudeJSON,
            credentials.claudeCredentialsJSON,
            credentials.claudeAuthJSON,
            credentials.keychainCredentials
        ]
            .compactMap { $0 }
            .lazy
            .compactMap(firstEmail(in:))
            .first
    }

    private func firstEmail(in text: String) -> String? {
        let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange]).lowercased()
    }

    private func loadStatusLineSnapshot() throws -> [String: Any]? {
        let path = AppPaths.claudeCodeStatusFile.path
        guard fileService.fileExists(at: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func makeWindow(status: [String: Any]?, key: String, label: String) -> QuotaWindow? {
        guard let rateLimits = status?["rate_limits"] as? [String: Any],
              let window = rateLimits[key] as? [String: Any],
              let usedPercentage = number(window["used_percentage"]) else {
            return nil
        }
        let resetAt = parseFlexibleDate(firstValue(
            in: window,
            keys: ["resets_at", "reset_at", "resetAt", "next_reset_at", "nextResetAt"]
        ))
        return QuotaWindow(
            label: label,
            used: min(max(usedPercentage, 0), 100),
            limit: 100,
            resetAt: resetAt
        )
    }

    private func shouldUseStatusLineSnapshot(_ status: [String: Any]?, settingsJSON: String?) -> Bool {
        guard status != nil else { return false }
        if hasRateLimitWindow(status) {
            return true
        }
        return quotaBarStatusLineIsInstalled(settingsJSON: settingsJSON)
    }

    private func hasRateLimitWindow(_ status: [String: Any]?) -> Bool {
        makeWindow(status: status, key: "five_hour", label: "5h") != nil
            || makeWindow(status: status, key: "seven_day", label: "7d") != nil
    }

#if DEBUG
    func parseStatusLineSnapshotForTesting(
        _ status: [String: Any],
        authMethod: String? = "oauth",
        apiProvider: String? = "firstParty",
        userID: String? = "fixture-user",
        authStatusJSON: String? = nil,
        claudeSettingsJSON: String? = nil,
        keychainCredentials: String? = nil
    ) -> QuotaSnapshot {
        let credentials = ClaudeCodeCredentials(
            loggedIn: true,
            authMethod: authMethod,
            apiProvider: apiProvider,
            userID: userID,
            claudeExecutablePath: nil,
            keychainCredentials: keychainCredentials,
            authStatusJSON: authStatusJSON,
            claudeSettingsJSON: claudeSettingsJSON,
            claudeJSON: nil,
            claudeCredentialsJSON: nil,
            claudeAuthJSON: nil
        )
        return makeQuotaSnapshot(status: status, credentials: credentials)
    }

    func shouldUseStatusLineSnapshotForTesting(_ status: [String: Any], settingsJSON: String? = nil) -> Bool {
        shouldUseStatusLineSnapshot(status, settingsJSON: settingsJSON)
    }
#endif

    private func makeQuotaSnapshot(status: [String: Any]?, credentials: ClaudeCodeCredentials) -> QuotaSnapshot {
        let primary = makeWindow(status: status, key: "five_hour", label: "5h")
        let secondary = makeWindow(status: status, key: "seven_day", label: "7d")
        let note = statusNote(status: status, credentials: credentials)

        return QuotaSnapshot(
            source: status == nil ? "Claude Code" : "Claude Code StatusLine",
            accountIdentifier: readableIdentity(from: credentials),
            planName: planName(credentials: credentials, status: status),
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: .init(),
            accountValidUntil: nil,
            subscriptionWillRenew: nil,
            subscriptionStatus: nil,
            isQuotaBlocked: isQuotaBlocked(primary: primary, secondary: secondary),
            note: note
        )
    }

    private func planName(credentials: ClaudeCodeCredentials, status: [String: Any]?) -> String? {
        if let thirdPartyProvider = thirdPartyProviderName(credentials: credentials, status: status) {
            return thirdPartyProvider
        }
        if isFirstPartyClaudeProvider(credentials.apiProvider) || credentials.authMethod == "oauth" {
            return "Claude.ai"
        }
        if let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return displayProviderName(from: provider)
        }
        return nil
    }

    private func statusNote(status: [String: Any]?, credentials: ClaudeCodeCredentials) -> String? {
        guard status != nil else {
            return "等待 Claude Code 会话同步；打开 Claude Code 并产生一次响应后会显示 5h/7d 用量。"
        }
        if ((status?["rate_limits"] as? [String: Any])?.isEmpty == false) {
            return nil
        }
        let rawProvider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isThirdParty = thirdPartyProviderName(credentials: credentials, status: status) != nil
            || (rawProvider?.isEmpty == false && !isFirstPartyClaudeProvider(rawProvider))
        if credentials.authMethod == "api_key" || isThirdParty {
            return "API Key / 第三方提供方模式通常没有 Pro/Max 5h/7d 用量条。"
        }
        return "Claude Code statusLine 已同步，但本次快照尚未包含 5h/7d 用量；下一次响应后会自动更新。"
    }

    private func isQuotaBlocked(primary: QuotaWindow?, secondary: QuotaWindow?) -> Bool? {
        guard primary != nil || secondary != nil else { return nil }
        return [primary, secondary]
            .compactMap { $0 }
            .contains { $0.usagePercent >= 0.999 }
    }

    private func parseCredentials(_ secret: String) throws -> ClaudeCodeCredentials {
        guard let data = secret.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
        }
        return try JSONDecoder().decode(ClaudeCodeCredentials.self, from: data)
    }

    private func encodeCredentials(_ credentials: ClaudeCodeCredentials) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(credentials)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func thirdPartyProviderName(credentials: ClaudeCodeCredentials, status: [String: Any]?) -> String? {
        let settings = credentials.claudeSettingsJSON.flatMap(parseJSONObject) as? [String: Any]
        if let env = settings?["env"] as? [String: Any] {
            if let baseURL = firstString(
                in: env,
                keys: ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_URL", "CLAUDE_BASE_URL"]
            ),
               let provider = providerName(fromBaseURL: baseURL) {
                return provider
            }

            if let model = firstString(
                in: env,
                keys: ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_MODEL", "CLAUDE_MODEL"]
            ),
               let provider = providerName(fromModel: model) {
                return provider
            }
        }

        if let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty,
           !isFirstPartyClaudeProvider(provider) {
            return displayProviderName(from: provider)
        }

        if let modelName = firstString(in: status as Any, keys: ["name", "display_name", "displayName", "model"]),
           let provider = providerName(fromModel: modelName) {
            return provider
        }

        return nil
    }

    private func providerName(fromBaseURL raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let host = URL(string: trimmed)?.host ?? URL(string: "https://\(trimmed)")?.host
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        if host == "api.anthropic.com" || host.hasSuffix(".anthropic.com") || host.hasSuffix(".claude.ai") {
            return nil
        }
        if host == "xiaomimimo.com" || host.hasSuffix(".xiaomimimo.com") {
            return "Xiaomi Mimo"
        }
        return host
            .split(separator: ".")
            .prefix(2)
            .map { part in part.prefix(1).uppercased() + part.dropFirst() }
            .joined(separator: " ")
    }

    private func providerName(fromModel raw: String) -> String? {
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !model.isEmpty else { return nil }
        if model.hasPrefix("mimo-") || model.contains("/mimo-") {
            return "Xiaomi Mimo"
        }
        return nil
    }

    private func isFirstPartyClaudeProvider(_ provider: String?) -> Bool {
        guard let normalized = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return false
        }
        return [
            "firstparty",
            "first_party",
            "claude.ai",
            "claude",
            "anthropic",
            "anthropic.com",
            "api.anthropic.com"
        ].contains(normalized)
    }

    private func displayProviderName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        if let mapped = providerName(fromBaseURL: trimmed) {
            return mapped
        }
        if let mapped = providerName(fromModel: trimmed) {
            return mapped
        }
        switch trimmed.lowercased() {
        case "firstparty", "first_party":
            return "Claude.ai"
        case "xiaomi", "mimo", "xiaomi_mimo", "xiaomi-mimo":
            return "Xiaomi Mimo"
        default:
            return trimmed
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private func parseJSONObject(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func firstValue(in dict: [String: Any], keys: Set<String>) -> Any? {
        for (key, value) in dict where keys.contains(key) {
            return value
        }
        return nil
    }

    private func firstString(in object: Any, keys: Set<String>) -> String? {
        findString(in: object, keys: keys)
    }

    private func findString(in object: Any, keys: Set<String>) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let text = string(value), !text.isEmpty {
                    return text
                }
                if let text = findString(in: value, keys: keys) {
                    return text
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let text = findString(in: value, keys: keys) {
                    return text
                }
            }
        }
        return nil
    }

    private func parseFlexibleDate(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber {
            return dateFromEpochOrSeconds(number.doubleValue)
        }
        if let double = raw as? Double {
            return dateFromEpochOrSeconds(double)
        }
        if let int = raw as? Int {
            return dateFromEpochOrSeconds(Double(int))
        }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let epoch = Double(trimmed) {
                return dateFromEpochOrSeconds(epoch)
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

    private func dateFromEpochOrSeconds(_ raw: Double) -> Date {
        raw > 2_000_000_000
            ? Date(timeIntervalSince1970: raw / 1000)
            : Date(timeIntervalSince1970: raw)
    }

    private func string(_ value: Any) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func mergeCredentials(
        preferred: ClaudeCodeCredentials,
        fallback: ClaudeCodeCredentials
    ) -> ClaudeCodeCredentials {
        ClaudeCodeCredentials(
            loggedIn: preferred.loggedIn,
            authMethod: preferred.authMethod ?? fallback.authMethod,
            apiProvider: preferred.apiProvider ?? fallback.apiProvider,
            userID: preferred.userID ?? fallback.userID,
            claudeExecutablePath: preferred.claudeExecutablePath ?? fallback.claudeExecutablePath,
            keychainCredentials: preferred.keychainCredentials ?? fallback.keychainCredentials,
            authStatusJSON: preferred.authStatusJSON ?? fallback.authStatusJSON,
            claudeSettingsJSON: preferred.claudeSettingsJSON ?? fallback.claudeSettingsJSON,
            claudeJSON: preferred.claudeJSON ?? fallback.claudeJSON,
            claudeCredentialsJSON: preferred.claudeCredentialsJSON ?? fallback.claudeCredentialsJSON,
            claudeAuthJSON: preferred.claudeAuthJSON ?? fallback.claudeAuthJSON
        )
    }

    private func claudeCredentialsRepresentSameAccount(
        _ lhs: ClaudeCodeCredentials,
        _ rhs: ClaudeCodeCredentials
    ) -> Bool {
        let lhsUserID = lhs.userID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let rhsUserID = rhs.userID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !lhsUserID.isEmpty || !rhsUserID.isEmpty {
            return !lhsUserID.isEmpty && lhsUserID == rhsUserID
        }

        if let lhsCredentials = lhs.keychainCredentials,
           let rhsCredentials = rhs.keychainCredentials,
           !lhsCredentials.isEmpty || !rhsCredentials.isEmpty {
            return lhsCredentials == rhsCredentials
        }

        return false
    }

    private func shouldClearStatusLineSnapshot(
        previous: ClaudeCodeCredentials?,
        next: ClaudeCodeCredentials
    ) -> Bool {
        guard let previous, previous.loggedIn else { return true }
        return !claudeCredentialsRepresentSameAccount(previous, next)
    }

    private func legacyIdentity(from credentials: ClaudeCodeCredentials) -> String {
        let method = credentials.authMethod?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return "claude-code:\(method):\(provider)".lowercased()
    }

    private func normalizeIdentityKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func stableCredentialFingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func uniqueIdentityAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        return aliases.filter { alias in
            seen.insert(normalizeIdentityKey(alias)).inserted
        }
    }

    private func runProcess(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
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
                throw ProviderError.unsupported("Claude Code 命令超时")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus == 0 {
            return output
        }
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw ProviderError.unsupported(error.isEmpty ? "Claude Code 命令执行失败" : error)
    }
}

private extension ClaudeCodeProvider {
    struct StatusLineInstallPaths {
        let claudeDirectory: URL
        let wrapperURL: URL
        let originalURL: URL
        let settingsURL: URL
    }

    var quotaBarStatusLineCommand: String {
        "~/.claude/quotabar-statusline.zsh"
    }

    func statusLineInstallPaths() -> StatusLineInstallPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        return StatusLineInstallPaths(
            claudeDirectory: claudeDirectory,
            wrapperURL: claudeDirectory.appendingPathComponent("quotabar-statusline.zsh"),
            originalURL: claudeDirectory.appendingPathComponent("quotabar-statusline-original.json"),
            settingsURL: claudeDirectory.appendingPathComponent("settings.json")
        )
    }

    func quotaBarStatusLineIsInstalled(settingsJSON: String?) -> Bool {
        guard let settingsJSON,
              let data = settingsJSON.data(using: .utf8),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = settings["statusLine"] as? [String: Any],
              statusLine["command"] as? String == quotaBarStatusLineCommand else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: statusLineInstallPaths().wrapperURL.path)
    }

    func installQuotaBarStatusLine() throws {
        let paths = statusLineInstallPaths()

        try FileManager.default.createDirectory(at: paths.claudeDirectory, withIntermediateDirectories: true)
        try writeStatusLineWrapper(to: paths.wrapperURL, originalURL: paths.originalURL)

        var settings = try loadSettings(from: paths.settingsURL)
        let currentStatusLine = settings["statusLine"] as? [String: Any]
        let currentCommand = currentStatusLine?["command"] as? String
        if currentCommand != quotaBarStatusLineCommand {
            try writeJSONObjectIfChanged(currentStatusLine ?? [:], to: paths.originalURL)
        }

        var nextStatusLine = currentStatusLine ?? [:]
        nextStatusLine["type"] = "command"
        nextStatusLine["command"] = quotaBarStatusLineCommand
        nextStatusLine["refreshInterval"] = nextStatusLine["refreshInterval"] ?? 30
        settings["statusLine"] = nextStatusLine
        try writeJSONObjectIfChanged(settings, to: paths.settingsURL)
    }

    func loadSettings(from url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return settings
    }

    func writeJSONObjectIfChanged(_ object: Any, to url: URL) throws {
        let canonicalData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if let currentData = try? Data(contentsOf: url),
           let currentObject = try? JSONSerialization.jsonObject(with: currentData),
           let currentCanonicalData = try? JSONSerialization.data(withJSONObject: currentObject, options: [.sortedKeys]),
           currentCanonicalData == canonicalData {
            return
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func writeStatusLineWrapper(to url: URL, originalURL: URL) throws {
        let snapshotPath = AppPaths.claudeCodeStatusFile.path
        let script = """
        #!/bin/zsh
        set -u

        INPUT="$(cat)"
        SNAPSHOT=\(shellQuoted(snapshotPath))
        ORIGINAL=\(shellQuoted(originalURL.path))

        mkdir -p "$(dirname "$SNAPSHOT")"
        TMP_FILE="${SNAPSHOT}.$$"
        printf '%s' "$INPUT" > "$TMP_FILE" && mv "$TMP_FILE" "$SNAPSHOT"

        ORIG_COMMAND="$(/usr/bin/python3 - "$ORIGINAL" <<'PY'
        import json
        import sys
        try:
            with open(sys.argv[1], "r", encoding="utf-8") as f:
                data = json.load(f)
            command = data.get("command") if isinstance(data, dict) else None
            print(command or "")
        except Exception:
            print("")
        PY
        )"

        if [[ -n "$ORIG_COMMAND" ]]; then
            printf '%s' "$INPUT" | /bin/zsh -lc "$ORIG_COMMAND"
            exit $?
        fi

        /usr/bin/python3 - "$SNAPSHOT" <<'PY'
        import json
        import sys
        try:
            with open(sys.argv[1], "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            print("Claude Code")
            raise SystemExit(0)

        model = (((data.get("model") or {}).get("display_name")) or "Claude").strip()
        limits = data.get("rate_limits") or {}
        parts = []
        for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
            value = (limits.get(key) or {}).get("used_percentage")
            if isinstance(value, (int, float)):
                parts.append(f"{label}: {value:.0f}%")
        print(f"[{model}] " + " ".join(parts) if parts else f"[{model}]")
        PY
        """

        try writeTextIfChanged(script, to: url)
        try setPosixPermissionsIfNeeded(0o700, for: url)
    }

    func writeTextIfChanged(_ text: String, to url: URL) throws {
        if let current = try? String(contentsOf: url, encoding: .utf8),
           current == text {
            return
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func setPosixPermissionsIfNeeded(_ permissions: Int, for url: URL) throws {
        let current = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        if current?.intValue == permissions {
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
