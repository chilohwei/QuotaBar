import Foundation

extension ClaudeCodeProvider {
    func readClaudeCodeCredentials() async throws -> ClaudeCodeCredentials {
        guard let executable = claudeExecutableURL() else {
            throw ProviderError.cliMissing(tool: .claudeCode, message: "未找到 Claude Code CLI。请先安装 claude，或确认 claude 命令可用。")
        }
        let keychainCredentials = try? readClaudeCodeKeychainCredentials()
        let claudeSettingsJSON = readTextIfExists(claudeSettingsURL())
        let claudeJSON = readTextIfExists(claudeJSONURL())
        let claudeCredentialsJSON = readTextIfExists(claudeCredentialsURL())
        let claudeAuthJSON = readTextIfExists(claudeAuthURL())
        let authentication = inferredClaudeAuthentication(
            keychainCredentials: keychainCredentials,
            claudeCredentialsJSON: claudeCredentialsJSON,
            claudeAuthJSON: claudeAuthJSON,
            claudeSettingsJSON: claudeSettingsJSON
        )

        return ClaudeCodeCredentials(
            loggedIn: authentication.loggedIn,
            authMethod: authentication.authMethod,
            apiProvider: authentication.apiProvider,
            userID: readClaudeUserID(),
            claudeExecutablePath: executable.path,
            keychainCredentials: keychainCredentials,
            authStatusJSON: nil,
            claudeSettingsJSON: claudeSettingsJSON,
            claudeJSON: claudeJSON,
            claudeCredentialsJSON: claudeCredentialsJSON,
            claudeAuthJSON: claudeAuthJSON
        )
    }

    struct InferredClaudeAuthentication: Equatable {
        let loggedIn: Bool
        let authMethod: String?
        let apiProvider: String?
    }

    func inferredClaudeAuthentication(
        keychainCredentials: String?,
        claudeCredentialsJSON: String?,
        claudeAuthJSON: String?,
        claudeSettingsJSON: String?
    ) -> InferredClaudeAuthentication {
        let settings = claudeSettingsJSON
            .flatMap(parseJSONObject) as? [String: Any]
        let environment = settings?["env"] as? [String: Any]
        let configuredProvider = firstString(
            in: environment ?? [:],
            keys: ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_URL", "CLAUDE_BASE_URL"]
        )
        let settingsHasAPISecret = firstString(
            in: environment ?? [:],
            keys: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        ) != nil
        if settingsHasAPISecret {
            return InferredClaudeAuthentication(
                loggedIn: true,
                authMethod: "api_key",
                apiProvider: configuredProvider ?? "api_key"
            )
        }

        let credentialSources = [
            keychainCredentials,
            claudeCredentialsJSON,
            claudeAuthJSON
        ].compactMap { $0 }
        if credentialSources.contains(where: { containsClaudeAPIKey(in: $0) }) {
            return InferredClaudeAuthentication(
                loggedIn: true,
                authMethod: "api_key",
                apiProvider: configuredProvider ?? "api_key"
            )
        }
        if credentialSources.contains(where: {
            parseOAuthToken(fromJSONText: $0) != nil || containsClaudeOAuthToken(in: $0)
        }) {
            return InferredClaudeAuthentication(
                loggedIn: true,
                authMethod: "oauth",
                apiProvider: "firstParty"
            )
        }
        return InferredClaudeAuthentication(
            loggedIn: false,
            authMethod: nil,
            apiProvider: configuredProvider
        )
    }

    private func containsClaudeAPIKey(in text: String) -> Bool {
        jsonContainsNonEmptyString(
            text,
            normalizedKeys: ["apikey", "anthropicapikey", "authtoken", "anthropicauthtoken"]
        )
    }

    private func containsClaudeOAuthToken(in text: String) -> Bool {
        jsonContainsNonEmptyString(
            text,
            normalizedKeys: ["accesstoken", "oauthtoken"]
        )
    }

    private func jsonContainsNonEmptyString(
        _ text: String,
        normalizedKeys: Set<String>
    ) -> Bool {
        guard let object = parseJSONObject(text) else { return false }
        func containsValue(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                for (key, nestedValue) in dictionary {
                    let normalizedKey = key
                        .lowercased()
                        .filter { $0.isLetter || $0.isNumber }
                    if normalizedKeys.contains(normalizedKey),
                       let string = nestedValue as? String,
                       !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return true
                    }
                    if containsValue(nestedValue) {
                        return true
                    }
                }
            } else if let array = value as? [Any] {
                return array.contains(where: containsValue)
            }
            return false
        }
        return containsValue(object)
    }

    var claudeLoginRequiredMessage: String {
        "Claude Code 尚未登录。为避免在 Launchpad 里创建 Claude Code URL Handler，QuotaBar 不会代替 Claude Code 执行 OAuth 登录；请先在 Claude Code 自身完成登录，然后回到 QuotaBar 点击添加。"
    }

    func openClaudeCodePage() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["https://claude.ai/code"]
        try? process.run()
    }

    func runClaudeAuthLogin(timeout: TimeInterval) async throws {
        guard let executable = claudeExecutableURL() else {
            throw ProviderError.cliMissing(tool: .claudeCode, message: "未找到 Claude Code CLI。请先安装 claude，或确认 claude 命令可用。")
        }
        _ = try await runProcess(
            executable: executable,
            arguments: ["auth", "login", "--claudeai"],
            timeout: timeout
        )
    }

    func claudeExecutableURL() -> URL? {
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

    func readClaudeUserID() -> String? {
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

    func writeClaudeUserID(_ userID: String?) throws {
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

    /// Copies the stored account's `oauthAccount` profile into the live `~/.claude.json`,
    /// leaving every other field — including the installation-scoped `userID`/`machineID` and
    /// the CLI's own caches — untouched. The keychain holds only tokens (no identity), so
    /// `claude auth status` reports whoever this cached profile describes; without the merge,
    /// a keychain swap would leave the CLI announcing the previous account.
    func writeClaudeOAuthAccount(from credentials: ClaudeCodeCredentials) throws {
        let url = claudeJSONURL()
        var live: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            live = existing
        }
        guard let merged = mergingClaudeOAuthAccount(into: live, from: credentials) else {
            return
        }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Pure merge behind `writeClaudeOAuthAccount`: swaps only `oauthAccount` into the live
    /// object. Everything else in `~/.claude.json` is installation state, not credentials —
    /// most notably `projects` (the per-project prompt history that lets `claude --continue`
    /// resume sessions after an account switch) — and must survive the swap.
    /// Returns nil when the stored snapshot carries no `oauthAccount` to merge.
    func mergingClaudeOAuthAccount(
        into liveObject: [String: Any],
        from credentials: ClaudeCodeCredentials
    ) -> [String: Any]? {
        guard let claudeJSON = credentials.claudeJSON,
              let storedObject = parseJSONObject(claudeJSON) as? [String: Any],
              let oauthAccount = storedObject["oauthAccount"] as? [String: Any] else {
            return nil
        }
        var object = liveObject
        object["oauthAccount"] = oauthAccount
        return object
    }

    func hasRestorableClaudeArtifacts(_ credentials: ClaudeCodeCredentials) -> Bool {
        [
            credentials.claudeCredentialsJSON,
            credentials.claudeAuthJSON
        ].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    func restoreClaudeArtifacts(from credentials: ClaudeCodeCredentials) throws {
        // The stored `claudeJSON` is a full snapshot of `~/.claude.json`, but it must never be
        // written back wholesale: that would roll the live file back to snapshot time, losing
        // `projects` prompt history (what `claude --continue` resumes from) and CLI caches.
        // Only the account identity and the installation `userID` belong to the restore.
        try writeClaudeOAuthAccount(from: credentials)
        try writeClaudeUserID(credentials.userID)

        if let claudeCredentialsJSON = credentials.claudeCredentialsJSON,
           !claudeCredentialsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try writeText(claudeCredentialsJSON, to: claudeCredentialsURL(), permissions: 0o600)
        }

        if let claudeAuthJSON = credentials.claudeAuthJSON,
           !claudeAuthJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try writeText(claudeAuthJSON, to: claudeAuthURL(), permissions: 0o600)
        }
    }

    func claudeJSONURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    func claudeCredentialsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
    }

    func claudeSettingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func claudeAuthURL() -> URL {
        claudeConfigDirectoryURL().appendingPathComponent("auth.json")
    }

    func claudeConfigDirectoryURL() -> URL {
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

    func readTextIfExists(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func writeText(_ text: String, to url: URL, permissions: Int?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    func readClaudeCodeKeychainCredentials() throws -> String? {
        try readKeychainPassword(service: "Claude Code-credentials")
    }

    func writeClaudeCodeKeychainCredentials(_ credentials: String) throws {
        // Must go through `/usr/bin/security`: the live item's ACL trusts only that binary, so
        // Security.framework SecItemAdd/Update fails closed (errSecAuthFailed) and previously
        // surfaced as "本地登录记录需要重新建立" while leaving the access token expired.
        try SystemSecretKeychainClient().writeGenericPasswordUsingSecurityTool(
            credentials,
            service: "Claude Code-credentials",
            account: NSUserName()
        )
    }

    func compareAndSwapClaudeCodeKeychainCredentials(
        expected: String,
        replacement: String
    ) -> Bool {
        // Same ACL constraint as the write path: Security.framework CAS cannot read or update
        // the item, so token renewal must read/compare/write via the trusted security tool.
        SystemSecretKeychainClient().compareAndSwapGenericPasswordUsingSecurityTool(
            expected: expected,
            replacement: replacement,
            service: "Claude Code-credentials",
            account: NSUserName()
        )
    }

    func readKeychainPassword(service: String) throws -> String? {
        // `Claude Code-credentials` is created by Claude Code via `/usr/bin/security`, so its
        // decrypt ACL trusts only that binary. A direct Security.framework read from QuotaBar
        // fails closed and would make `readClaudeCodeCredentials` report a signed-in account as
        // logged out — the "还没有登录" failure when adding an account right after login. Read
        // through the trusted tool instead.
        SystemSecretKeychainClient().readGenericPasswordUsingSecurityTool(service: service)
    }

    func readableIdentity(from credentials: ClaudeCodeCredentials) -> String? {
        if let email = readableEmail(from: credentials) {
            return email
        }
        // The account UUID, never `userID`: the latter is installation-scoped and identical for
        // every account on this machine.
        guard let accountUuid = claudeAccountUuid(from: credentials) else {
            return nil
        }
        return "Claude \(String(accountUuid.suffix(8)))"
    }

    func readableEmail(from credentials: ClaudeCodeCredentials) -> String? {
        // Structured sources first: `claude auth status`'s `email` field and the cached
        // `oauthAccount.emailAddress` name the login precisely, while the regex scan below can
        // latch onto any address that merely appears in the blobs (e.g. an org name).
        if let email = claudeAccountEmail(from: credentials) {
            return email
        }
        return [
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

    func firstEmail(in text: String) -> String? {
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

    struct StatusLineSnapshotLoad {
        let status: [String: Any]
        let capturedAt: Date
    }

    struct ClaudeRateLimitEvent {
        let resetAt: Date?
        let capturedAt: Date
        let message: String?
    }

    struct ActiveRateLimit {
        let resetAt: Date?
    }

}
