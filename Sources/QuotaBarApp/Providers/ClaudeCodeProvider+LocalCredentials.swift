import Foundation

extension ClaudeCodeProvider {
    func readClaudeCodeCredentials() async throws -> ClaudeCodeCredentials {
        guard let executable = claudeExecutableURL() else {
            throw ProviderError.cliMissing(tool: .claudeCode, message: "未找到 Claude Code CLI。请先安装 claude，或确认 claude 命令可用。")
        }
        // `claude auth status` only reports auth state — verified against CLI 2.x, it returns
        // loggedIn:true while leaving an expired keychain token untouched (and there is no
        // `auth refresh` subcommand). Renewal of a lapsed token happens in
        // ClaudeCodeProvider+TokenRefresh. The generous timeout is for cold CLI startup.
        let output = try await runProcess(executable: executable, arguments: ["auth", "status"], timeout: 30)
        guard let data = output.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.credentialParsingFailed(tool: .claudeCode)
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

    func hasRestorableClaudeArtifacts(_ credentials: ClaudeCodeCredentials) -> Bool {
        [
            credentials.claudeCredentialsJSON,
            credentials.claudeAuthJSON
        ].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    func restoreClaudeArtifacts(from credentials: ClaudeCodeCredentials) throws {
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

    func readKeychainPassword(service: String) throws -> String? {
        let value = try runSecurity(arguments: [
            "find-generic-password",
            "-s",
            service,
            "-w"
        ], capturePassword: true)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func runSecurity(arguments: [String], capturePassword: Bool) throws -> String {
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

    func readableIdentity(from credentials: ClaudeCodeCredentials) -> String? {
        if let email = readableEmail(from: credentials) {
            return email
        }
        guard let userID = credentials.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userID.isEmpty else {
            return nil
        }
        return "Claude \(String(userID.suffix(8)))"
    }

    func readableEmail(from credentials: ClaudeCodeCredentials) -> String? {
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
