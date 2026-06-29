import CryptoKit
import Foundation

struct ClaudeCodeProvider: Provider {
    let tool: ToolKind = .claudeCode

    private static let oauthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let oauthTokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let oauthUsageUserAgent = "claude-code/2.1.181"
    // Refresh the access token this long before its stored expiry, so `/usage` calls never go out
    // with an already-dead token.
    private static let oauthTokenExpiryMargin: TimeInterval = 2 * 60
    // Floor between real `/usage` network calls per account. Bursty triggers (panel open, foreground,
    // statusLine change) within this window reuse the last live snapshot instead of re-hitting the
    // endpoint, which keeps QuotaBar from tripping the endpoint's own per-account rate limit.
    private static let liveUsageMinFetchInterval: TimeInterval = 60
    // When `/usage` is temporarily unavailable, the last live snapshot may be shown — clearly
    // labeled with its age — up to this old, instead of falling back to stale statusLine data.
    private static let liveUsageStaleMax: TimeInterval = 30 * 60
    // After a token refresh fails, wait this long before trying again, so a throttled auth endpoint
    // is given room to recover instead of being hammered on every poll cycle.
    private static let tokenRefreshCooldown: TimeInterval = 5 * 60
    private static let rateLimitTranscriptLookback: TimeInterval = 24 * 60 * 60
    private static let recentTranscriptFileLimit = 16
    private static let transcriptTailByteLimit: UInt64 = 512 * 1024
    private static let rateLimitWithoutResetFreshness: TimeInterval = 10 * 60
    private static let rateLimitReachedNote =
        "Claude Code 已提示 Usage limit reached；QuotaBar 在重置前按 0% 剩余额度显示。"
    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

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
        try await fetchQuota(account: account, secret: secret, forceRefresh: false)
    }

    func fetchQuota(account: Account, secret: String, forceRefresh: Bool) async throws -> QuotaSnapshot {
        let storedCredentials = try parseCredentials(secret)
        let credentials: ClaudeCodeCredentials
        if let latest = try? await readClaudeCodeCredentials(),
           claudeCredentialsRepresentSameAccount(latest, storedCredentials) {
            credentials = mergeCredentials(preferred: latest, fallback: storedCredentials)
        } else {
            credentials = storedCredentials
        }

        let now = Date()
        let statusLineLoad = try? loadStatusLineSnapshot()
        let rateLimitEvent = loadActiveRateLimitEvent(status: statusLineLoad?.status, now: now)

        // The live OAuth `utilization` numbers track the 5h/7d rolling windows, which are
        // distinct from the session limit Claude Code reports via a 429 "Usage limit reached".
        // When a session limit is active those windows can still read well under 100%, so the
        // active rate-limit event must be overlaid onto the live snapshot too — otherwise the
        // panel keeps showing stale "remaining" while Claude Code is blocked.
        if let liveSnapshot = await fetchOAuthUsageSnapshot(credentials: credentials, forceRefresh: forceRefresh) {
            return applyActiveRateLimit(to: liveSnapshot, rateLimitEvent: rateLimitEvent, now: now)
        }

        let status = shouldUseStatusLineSnapshot(statusLineLoad?.status, settingsJSON: credentials.claudeSettingsJSON)
            ? statusLineLoad?.status
            : nil

        return makeQuotaSnapshot(
            status: status,
            credentials: credentials,
            capturedAt: statusLineLoad?.capturedAt,
            now: now,
            rateLimitEvent: rateLimitEvent
        )
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

    private struct StatusLineSnapshotLoad {
        let status: [String: Any]
        let capturedAt: Date
    }

    private struct ClaudeRateLimitEvent {
        let resetAt: Date?
        let capturedAt: Date
        let message: String?
    }

    private struct ActiveRateLimit {
        let resetAt: Date?
    }

    private func loadStatusLineSnapshot() throws -> StatusLineSnapshotLoad? {
        let url = AppPaths.claudeCodeStatusFile
        let path = url.path
        guard fileService.fileExists(at: path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let status = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let capturedAt = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            ?? Date()
        return StatusLineSnapshotLoad(status: status, capturedAt: capturedAt)
    }

    private func makeWindow(
        status: [String: Any]?,
        key: String,
        label: String,
        now: Date = Date(),
        rejectExpiredWindows: Bool = true
    ) -> QuotaWindow? {
        guard let rateLimits = status?["rate_limits"] as? [String: Any],
              let window = rateLimits[key] as? [String: Any],
              let usedPercentage = number(window["used_percentage"]) else {
            return nil
        }
        let resetAt = parseFlexibleDate(firstValue(
            in: window,
            keys: ["resets_at", "reset_at", "resetAt", "next_reset_at", "nextResetAt"]
        ))
        // The statusLine snapshot is only a fallback for when live `/usage` is unavailable, and
        // Claude Code freezes its `rate_limits` between API calls. Once a window's reset time has
        // passed, its stored `used_percentage` belongs to a previous cycle and we have no truthful
        // current value — drop it rather than show a stale or invented number. The live `/usage`
        // path is the source of truth for an accurate, current figure.
        if rejectExpiredWindows, let resetAt, resetAt.addingTimeInterval(60) < now {
            return nil
        }
        return QuotaWindow(
            label: label,
            used: min(max(usedPercentage, 0), 100),
            limit: 100,
            resetAt: resetAt
        )
    }

    private func loadActiveRateLimitEvent(status: [String: Any]?, now: Date) -> ClaudeRateLimitEvent? {
        transcriptURLs(status: status, now: now)
            .compactMap { latestRateLimitEvent(in: $0, now: now) }
            .filter { activeRateLimit(from: $0, fallbackResetAt: nil, now: now) != nil }
            .sorted { $0.capturedAt > $1.capturedAt }
            .first
    }

    private func latestRateLimitEvent(in url: URL, now: Date) -> ClaudeRateLimitEvent? {
        guard let text = readTailText(from: url, byteLimit: Self.transcriptTailByteLimit) else {
            return nil
        }

        let fileModifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var latest: ClaudeRateLimitEvent?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let event = parseRateLimitEvent(
                jsonLine: String(rawLine),
                fileModifiedAt: fileModifiedAt,
                now: now
            ),
                  activeRateLimit(from: event, fallbackResetAt: nil, now: now) != nil else {
                continue
            }
            if latest == nil || event.capturedAt > latest!.capturedAt {
                latest = event
            }
        }
        return latest
    }

    private func transcriptURLs(status: [String: Any]?, now: Date) -> [URL] {
        var urls: [URL] = []
        if let transcriptPath = firstString(
            in: status as Any,
            keys: ["transcript_path", "transcriptPath", "transcript"]
        ) {
            urls.append(URL(fileURLWithPath: fileService.expand(path: transcriptPath)))
        }

        urls.append(contentsOf: recentClaudeProjectTranscriptURLs(now: now))

        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted
        }
    }

    private func recentClaudeProjectTranscriptURLs(now: Date) -> [URL] {
        let projectsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modifiedAt) <= Self.rateLimitTranscriptLookback else { continue }
            entries.append((url, modifiedAt))
        }

        return Array(
            entries
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(Self.recentTranscriptFileLimit)
                .map(\.url)
        )
    }

    private func readTailText(from url: URL, byteLimit: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            let fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: fileSize > byteLimit ? fileSize - byteLimit : 0)
            guard let data = try handle.readToEnd(), !data.isEmpty else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func parseRateLimitEvent(
        jsonLine: String,
        fileModifiedAt: Date?,
        now: Date
    ) -> ClaudeRateLimitEvent? {
        let trimmed = jsonLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("429")
            || trimmed.localizedCaseInsensitiveContains("rate_limit")
            || trimmed.localizedCaseInsensitiveContains("usage limit")
            || trimmed.localizedCaseInsensitiveContains("session limit") else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return parseRateLimitEvent(object: object, fileModifiedAt: fileModifiedAt, now: now)
    }

    private func parseRateLimitEvent(
        object: Any,
        fileModifiedAt: Date?,
        now: Date
    ) -> ClaudeRateLimitEvent? {
        guard let dict = object as? [String: Any] else { return nil }

        // A genuine Claude Code rate-limit record carries these markers at the TOP LEVEL of the
        // transcript entry. The earlier heuristic also matched on free text ("usage limit" /
        // "session limit" + "reset") found anywhere in the line, which misfired on any transcript
        // that merely *mentions* a limit — tool output, assistant discussion, even this debugging
        // session — forcing a false "blocked". Read the structural fields directly (not a
        // recursive search, which could pick up such strings nested inside content).
        let isApiErrorMessage = (dict["isApiErrorMessage"] as? Bool) == true
        let statusCode = number(dict["apiErrorStatus"])
        let errorCode = (dict["error"] as? String)?.lowercased()
        let isRateLimit = isApiErrorMessage
            && (Int(statusCode ?? -1) == 429 || errorCode == "rate_limit")
        guard isRateLimit else { return nil }

        var strings: [String] = []
        collectStrings(in: dict, into: &strings)
        let joinedText = strings.joined(separator: " ")

        let capturedAt = parseFlexibleDate(findValue(in: dict, keys: ["timestamp", "createdAt", "created_at"]))
            ?? fileModifiedAt
            ?? now
        let resetAt = parseFlexibleDate(findValue(
            in: dict,
            keys: ["resets_at", "reset_at", "resetAt", "retryAt", "retry_at"]
        )) ?? parseRateLimitResetDate(in: joinedText, referenceDate: capturedAt)
        let message = strings.first { value in
            let lower = value.lowercased()
            return lower.contains("limit") && lower.contains("reset")
        }

        return ClaudeRateLimitEvent(resetAt: resetAt, capturedAt: capturedAt, message: message)
    }

    private func activeRateLimit(
        from event: ClaudeRateLimitEvent?,
        fallbackResetAt: Date?,
        now: Date
    ) -> ActiveRateLimit? {
        guard let event else { return nil }
        if let resetAt = event.resetAt ?? fallbackResetAt {
            return resetAt.addingTimeInterval(60) > now ? ActiveRateLimit(resetAt: resetAt) : nil
        }
        return now.timeIntervalSince(event.capturedAt) <= Self.rateLimitWithoutResetFreshness
            ? ActiveRateLimit(resetAt: nil)
            : nil
    }

    private func parseOAuthUsageWindow(_ dict: [String: Any]?, label: String) -> QuotaWindow? {
        guard let dict else { return nil }
        guard let used = number(dict["utilization"]) ?? number(dict["used_percentage"]) else {
            return nil
        }
        let resetAt = parseFlexibleDate(dict["resets_at"] ?? dict["reset_at"] ?? dict["resetAt"])
        return QuotaWindow(
            label: label,
            used: min(max(used, 0), 100),
            limit: 100,
            resetAt: resetAt
        )
    }

    private func shouldFetchOAuthUsage(_ credentials: ClaudeCodeCredentials) -> Bool {
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

    private struct ClaudeOAuthToken {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    private struct RefreshedOAuthToken {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date?
    }

    private struct CachedClaudeUsage: Codable {
        let schemaVersion: Int
        let cachedAt: Date
        let snapshot: QuotaSnapshot
    }

    private func parseOAuthToken(from credentials: ClaudeCodeCredentials) -> ClaudeOAuthToken? {
        for source in [credentials.keychainCredentials, credentials.claudeCredentialsJSON] {
            guard let text = source?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = object["claudeAiOauth"] as? [String: Any] else {
                continue
            }
            let access = ((oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !access.isEmpty else { continue }
            let refresh = ((oauth["refreshToken"] as? String) ?? (oauth["refresh_token"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ClaudeOAuthToken(
                accessToken: access,
                refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
                expiresAt: parseFlexibleDate(oauth["expiresAt"] ?? oauth["expires_at"])
            )
        }
        return nil
    }

    private func fetchOAuthUsageSnapshot(
        credentials: ClaudeCodeCredentials,
        forceRefresh: Bool
    ) async -> QuotaSnapshot? {
        guard shouldFetchOAuthUsage(credentials),
              let token = parseOAuthToken(from: credentials) else {
            return nil
        }

        let cacheKey = usageCacheKey(credentials)
        let cached = cacheKey.flatMap { try? loadCachedUsage(cacheKey: $0) }

        // Collapse bursty triggers: a very recent live snapshot is reused as-is, so QuotaBar does
        // not re-hit the endpoint (and trip its per-account rate limit) several times a minute.
        if !forceRefresh,
           let cached,
           Date().timeIntervalSince(cached.cachedAt) < Self.liveUsageMinFetchInterval {
            return cached.snapshot
        }

        let isExpired = token.expiresAt.map { $0.timeIntervalSinceNow <= Self.oauthTokenExpiryMargin } ?? false
        var accessToken = token.accessToken
        var didRefresh = false
        if isExpired {
            // The token is dead; refreshing it is the only way to get live data. If the refresh is
            // in cooldown (a recent attempt failed), don't call either endpoint — a dead token only
            // yields 401s and hammering keeps the auth endpoint throttled. Show honest stale data.
            guard let refreshed = await refreshAccessTokenIfAllowed(refreshToken: token.refreshToken, cacheKey: cacheKey) else {
                return staleLiveFallback(cached)
            }
            accessToken = refreshed
            didRefresh = true
        }

        do {
            let payload = try await requestOAuthUsage(accessToken: accessToken)
            let snapshot = makeOAuthUsageSnapshot(payload: payload, credentials: credentials)
            if let cacheKey { try? storeCachedUsage(snapshot, cacheKey: cacheKey) }
            return snapshot
        } catch OAuthUsageFetchError.unauthorized where !didRefresh {
            // Token looked locally valid but was rejected — refresh once (if allowed) and retry.
            if let refreshed = await refreshAccessTokenIfAllowed(refreshToken: token.refreshToken, cacheKey: cacheKey),
               let payload = try? await requestOAuthUsage(accessToken: refreshed) {
                let snapshot = makeOAuthUsageSnapshot(payload: payload, credentials: credentials)
                if let cacheKey { try? storeCachedUsage(snapshot, cacheKey: cacheKey) }
                return snapshot
            }
        } catch {
            // fall through to the stale-but-honest fallback below
        }

        return staleLiveFallback(cached)
    }

    /// The last real `/usage` value, labeled with its age, while recent enough to be meaningful.
    /// Never fabricated and never the frozen statusLine — just the last truth, honestly aged.
    private func staleLiveFallback(_ cached: CachedClaudeUsage?) -> QuotaSnapshot? {
        guard let cached,
              Date().timeIntervalSince(cached.cachedAt) <= Self.liveUsageStaleMax else {
            return nil
        }
        let minutes = max(1, Int(Date().timeIntervalSince(cached.cachedAt) / 60))
        return cached.snapshot.replacing(
            source: "Claude Code OAuth Cache",
            updatedAt: cached.cachedAt,
            note: "实时接口暂不可用，显示约 \(minutes) 分钟前的真实额度。"
        )
    }

    /// Refreshes the access token unless a recent refresh failed and we're still in its cooldown.
    /// On failure it sets a cooldown so the app stops hammering the auth endpoint every poll cycle
    /// (which would otherwise sustain the very rate limit that's blocking recovery).
    private func refreshAccessTokenIfAllowed(refreshToken: String?, cacheKey: String?) async -> String? {
        if let until = tokenRefreshBlockedUntil(cacheKey), until > Date() {
            return nil
        }
        do {
            let access = try await refreshAndPersistToken(refreshToken: refreshToken)
            clearTokenRefreshBackoff(cacheKey)
            return access
        } catch {
            setTokenRefreshBackoff(cacheKey)
            return nil
        }
    }

    private func requestTokenRefresh(refreshToken: String) async throws -> RefreshedOAuthToken {
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
        case 401, 403:
            throw OAuthUsageFetchError.unauthorized
        case 429:
            throw OAuthUsageFetchError.rateLimited
        default:
            throw OAuthUsageFetchError.httpStatus(http.statusCode)
        }
    }

    @discardableResult
    private func refreshAndPersistToken(refreshToken: String?) async throws -> String {
        guard let refreshToken, !refreshToken.isEmpty else {
            throw OAuthUsageFetchError.unauthorized
        }
        let refreshed = try await requestTokenRefresh(refreshToken: refreshToken)
        try? writeRefreshedOAuthToken(refreshed)
        return refreshed.accessToken
    }

    /// Merges rotated tokens back into the keychain credentials, preserving every other field.
    private func writeRefreshedOAuthToken(_ token: RefreshedOAuthToken) throws {
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

    private func usageCacheKey(_ credentials: ClaudeCodeCredentials) -> String? {
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

    private func usageCachePath(cacheKey: String) -> String {
        AppPaths.quotaCacheDirectory.appendingPathComponent("\(cacheKey).json").path
    }

    private func loadCachedUsage(cacheKey: String) throws -> CachedClaudeUsage {
        let text = try fileService.readText(at: usageCachePath(cacheKey: cacheKey))
        guard let data = text.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
        }
        return try JSONDecoder().decode(CachedClaudeUsage.self, from: data)
    }

    private func storeCachedUsage(_ snapshot: QuotaSnapshot, cacheKey: String) throws {
        try fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        let cached = CachedClaudeUsage(schemaVersion: 1, cachedAt: Date(), snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cached)
        try fileService.writeText(String(data: data, encoding: .utf8) ?? "{}", to: usageCachePath(cacheKey: cacheKey))
    }

    private func tokenRefreshBackoffPath(_ cacheKey: String) -> String {
        AppPaths.quotaCacheDirectory.appendingPathComponent("\(cacheKey)-refresh-backoff").path
    }

    private func tokenRefreshBlockedUntil(_ cacheKey: String?) -> Date? {
        guard let cacheKey,
              let text = try? fileService.readText(at: tokenRefreshBackoffPath(cacheKey)),
              let epoch = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    private func setTokenRefreshBackoff(_ cacheKey: String?) {
        guard let cacheKey else { return }
        try? fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        let until = Date().addingTimeInterval(Self.tokenRefreshCooldown).timeIntervalSince1970
        try? fileService.writeText(String(until), to: tokenRefreshBackoffPath(cacheKey))
    }

    private func clearTokenRefreshBackoff(_ cacheKey: String?) {
        guard let cacheKey else { return }
        try? fileService.removeItemIfExists(at: tokenRefreshBackoffPath(cacheKey))
    }

    private func requestOAuthUsage(accessToken: String) async throws -> [String: Any] {
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
            throw OAuthUsageFetchError.rateLimited
        default:
            throw OAuthUsageFetchError.httpStatus(http.statusCode)
        }
    }

    private func makeOAuthUsageSnapshot(
        payload: [String: Any],
        credentials: ClaudeCodeCredentials
    ) -> QuotaSnapshot {
        let primary = parseOAuthUsageWindow(payload["five_hour"] as? [String: Any], label: "5h")
        let secondary = parseOAuthUsageWindow(payload["seven_day"] as? [String: Any], label: "7d")

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
            note: nil
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
        makeWindow(status: status, key: "five_hour", label: "5h", rejectExpiredWindows: false) != nil
            || makeWindow(status: status, key: "seven_day", label: "7d", rejectExpiredWindows: false) != nil
    }

#if DEBUG
    func parseStatusLineSnapshotForTesting(
        _ status: [String: Any],
        authMethod: String? = "oauth",
        apiProvider: String? = "firstParty",
        userID: String? = "fixture-user",
        authStatusJSON: String? = nil,
        claudeSettingsJSON: String? = nil,
        keychainCredentials: String? = nil,
        capturedAt: Date = Date(),
        now: Date = Date(),
        rateLimitTranscriptLine: String? = nil
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
        let rateLimitEvent = rateLimitTranscriptLine.flatMap {
            parseRateLimitEvent(jsonLine: $0, fileModifiedAt: nil, now: now)
        }
        return makeQuotaSnapshot(
            status: status,
            credentials: credentials,
            capturedAt: capturedAt,
            now: now,
            rateLimitEvent: rateLimitEvent
        )
    }

    func parseOAuthUsagePayloadForTesting(
        _ payload: [String: Any],
        authMethod: String? = "oauth",
        apiProvider: String? = "firstParty",
        userID: String? = "fixture-user",
        authStatusJSON: String? = nil,
        now: Date = Date(),
        rateLimitTranscriptLine: String? = nil
    ) -> QuotaSnapshot {
        let credentials = ClaudeCodeCredentials(
            loggedIn: true,
            authMethod: authMethod,
            apiProvider: apiProvider,
            userID: userID,
            claudeExecutablePath: nil,
            keychainCredentials: nil,
            authStatusJSON: authStatusJSON,
            claudeSettingsJSON: nil,
            claudeJSON: nil,
            claudeCredentialsJSON: nil,
            claudeAuthJSON: nil
        )
        let snapshot = makeOAuthUsageSnapshot(payload: payload, credentials: credentials)
        let rateLimitEvent = rateLimitTranscriptLine.flatMap {
            parseRateLimitEvent(jsonLine: $0, fileModifiedAt: nil, now: now)
        }
        return applyActiveRateLimit(to: snapshot, rateLimitEvent: rateLimitEvent, now: now)
    }

    func shouldUseStatusLineSnapshotForTesting(_ status: [String: Any], settingsJSON: String? = nil) -> Bool {
        shouldUseStatusLineSnapshot(status, settingsJSON: settingsJSON)
    }
#endif

    private func makeQuotaSnapshot(
        status: [String: Any]?,
        credentials: ClaudeCodeCredentials,
        capturedAt: Date? = nil,
        now: Date = Date(),
        rateLimitEvent: ClaudeRateLimitEvent? = nil
    ) -> QuotaSnapshot {
        let primary = makeWindow(status: status, key: "five_hour", label: "5h", now: now)
        let secondary = makeWindow(status: status, key: "seven_day", label: "7d", now: now)
        let base = QuotaSnapshot(
            source: status == nil ? "Claude Code" : "Claude Code StatusLine",
            accountIdentifier: readableIdentity(from: credentials),
            planName: planName(credentials: credentials, status: status),
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: capturedAt ?? now,
            accountValidUntil: nil,
            subscriptionWillRenew: nil,
            subscriptionStatus: nil,
            isQuotaBlocked: isQuotaBlocked(primary: primary, secondary: secondary),
            note: statusNote(
                status: status,
                credentials: credentials,
                hadExpiredWindows: hadExpiredStatusLineWindows(status: status, now: now)
            )
        )
        return applyActiveRateLimit(to: base, rateLimitEvent: rateLimitEvent, now: now)
    }

    /// Overlays an active session/rate limit onto an existing snapshot (e.g. the live OAuth
    /// snapshot, whose rolling-window utilization does not reflect a session limit). When a
    /// limit is active the primary window is forced to 0% remaining and the snapshot is marked
    /// blocked, mirroring what Claude Code shows as "Usage limit reached".
    private func applyActiveRateLimit(
        to snapshot: QuotaSnapshot,
        rateLimitEvent: ClaudeRateLimitEvent?,
        now: Date
    ) -> QuotaSnapshot {
        guard let activeRateLimit = activeRateLimit(
            from: rateLimitEvent,
            fallbackResetAt: snapshot.primary?.resetAt,
            now: now
        ) else {
            return snapshot
        }

        // `activeRateLimit.resetAt` already falls back to the primary window's reset time.
        let primary = QuotaWindow(
            label: snapshot.primary?.label ?? "5h",
            used: 100,
            limit: 100,
            resetAt: activeRateLimit.resetAt
        )

        return QuotaSnapshot(
            source: snapshot.source,
            accountIdentifier: snapshot.accountIdentifier,
            planName: snapshot.planName,
            primary: primary,
            secondary: snapshot.secondary,
            tertiary: snapshot.tertiary,
            creditsRemaining: snapshot.creditsRemaining,
            creditsTotal: snapshot.creditsTotal,
            updatedAt: snapshot.updatedAt,
            periodEnd: snapshot.periodEnd,
            accountValidUntil: snapshot.accountValidUntil,
            subscriptionWillRenew: snapshot.subscriptionWillRenew,
            subscriptionStatus: snapshot.subscriptionStatus,
            isQuotaBlocked: true,
            note: Self.rateLimitReachedNote
        )
    }

    private func hadExpiredStatusLineWindows(status: [String: Any]?, now: Date) -> Bool {
        guard let status else { return false }
        let snapshot = QuotaSnapshot(
            source: "Claude Code StatusLine",
            primary: makeWindow(status: status, key: "five_hour", label: "5h", now: now, rejectExpiredWindows: false),
            secondary: makeWindow(status: status, key: "seven_day", label: "7d", now: now, rejectExpiredWindows: false),
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: now,
            note: nil
        )
        return QuotaFreshness.hasExpiredQuotaWindows(snapshot, now: now)
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

    // Note for the non-rate-limited case; an active session limit replaces this with
    // `rateLimitReachedNote` in `applyActiveRateLimit`.
    private func statusNote(
        status: [String: Any]?,
        credentials: ClaudeCodeCredentials,
        hadExpiredWindows: Bool = false
    ) -> String? {
        guard status != nil else {
            return "等待 Claude Code 会话同步；打开 Claude Code 并产生一次响应后会显示 5h/7d 用量。"
        }
        if hadExpiredWindows {
            return "Claude Code statusLine 用量窗口已过期；正在拉取实时数据，或在 Claude Code 成功响应后自动同步。"
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

    private func findValue(in object: Any, keys: Set<String>) -> Any? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key) {
                    return value
                }
                if let found = findValue(in: value, keys: keys) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findValue(in: value, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    private func collectStrings(in object: Any, into strings: inout [String]) {
        guard strings.count < 200 else { return }
        if let text = object as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                strings.append(String(trimmed.prefix(2_000)))
            }
        } else if let dict = object as? [String: Any] {
            for value in dict.values {
                collectStrings(in: value, into: &strings)
                if strings.count >= 200 { break }
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectStrings(in: value, into: &strings)
                if strings.count >= 200 { break }
            }
        }
    }

    private func parseRateLimitResetDate(in text: String, referenceDate: Date) -> Date? {
        let pattern = #"(?i)\breset(?:s)?(?:\s+at)?\s+([0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)?)(?:\s*\(([A-Za-z_]+/[A-Za-z_]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let timeRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let timeZone: TimeZone
        if match.numberOfRanges > 2,
           let zoneRange = Range(match.range(at: 2), in: text),
           let parsed = TimeZone(identifier: String(text[zoneRange])) {
            timeZone = parsed
        } else {
            timeZone = .current
        }

        return parseResetTimeOfDay(
            String(text[timeRange]),
            timeZone: timeZone,
            referenceDate: referenceDate
        )
    }

    private func parseResetTimeOfDay(
        _ raw: String,
        timeZone: TimeZone,
        referenceDate: Date
    ) -> Date? {
        if let directDate = parseFlexibleDate(raw) {
            return directDate
        }

        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false
        let formats = ["H:mm", "HH:mm", "H", "h:mma", "ha"]

        for format in formats {
            formatter.dateFormat = format
            guard let parsedTime = formatter.date(from: normalized) else { continue }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let timeComponents = calendar.dateComponents([.hour, .minute], from: parsedTime)
            var resetComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            resetComponents.hour = timeComponents.hour
            resetComponents.minute = timeComponents.minute ?? 0
            resetComponents.second = 0

            guard var resetAt = calendar.date(from: resetComponents) else { continue }
            if resetAt.addingTimeInterval(60) < referenceDate,
               let nextDay = calendar.date(byAdding: .day, value: 1, to: resetAt) {
                resetAt = nextDay
            }
            return resetAt
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

private enum OAuthUsageFetchError: Error, Equatable {
    case unauthorized
    case rateLimited
    case invalidResponse
    case httpStatus(Int)
}
