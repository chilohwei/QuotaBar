import AppKit
import Foundation

extension CodexProvider {
    func importCurrentCredentials() async throws -> String {
        try fileService.readText(at: activeAuthPath)
    }

    func updateCurrentCredentials(_ secret: String) async throws {
        try ensureFileCredentialStore(at: activeConfigPath)
        try fileService.writeTextWithBackup(secret, to: activeAuthPath, backupBaseName: "auth.json", permissions: 0o600)
    }

    func persistRefreshedSecret(_ secret: String, for account: Account, isActive: Bool) async throws {
        let managedHome = account.settings.codexHomePath ?? AppPaths.managedCodexHomePath(accountID: account.id)
        try ensureFileCredentialStore(at: "\(managedHome)/config.toml")
        try fileService.writeTextWithBackup(secret, to: "\(managedHome)/auth.json", backupBaseName: "auth.json", permissions: 0o600)
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
            throw ProviderError.cliMissing(tool: .codex, message: "未找到 Codex CLI。请先安装 Codex，或确认 codex 命令可用。")
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
        throw ProviderError.loginIncomplete(tool: .codex, message: message)
    }

    func codexLoginAttempts() -> [CodexLoginAttempt] {
        let fileCredentialStoreOverride = #"cli_auth_credentials_store="file""#
        return [
            CodexLoginAttempt(
                name: "浏览器登录",
                arguments: ["login", "-c", fileCredentialStoreOverride],
                timeout: 180,
                opensDevicePrompt: false
            ),
            CodexLoginAttempt(
                name: "设备码登录",
                arguments: ["login", "-c", fileCredentialStoreOverride, "--device-auth"],
                timeout: 15 * 60,
                opensDevicePrompt: true
            )
        ]
    }

    func runLoginAttempt(
        _ attempt: CodexLoginAttempt,
        codexExecutable: URL,
        scratchHome: URL
    ) async throws -> String {
        await MainActor.run {
            LoginFlowProgress.shared.begin(
                method: attempt.opensDevicePrompt ? .deviceCode : .browser,
                timeout: attempt.timeout
            )
        }

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
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                    LoginFlowProgress.shared.setReopenAction {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if let prompt = devicePromptScanner?.append(data) {
                Task { @MainActor in
                    LoginFlowProgress.shared.setReopenAction {
                        NSWorkspace.shared.open(prompt.url)
                    }
                    Self.presentDeviceAuthPrompt(prompt)
                }
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw ProviderError.cliMissing(tool: .codex, message: "未找到 codex 命令，请先安装 Codex CLI")
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
            throw ProviderError.loginIncomplete(tool: .codex, message: attempt.opensDevicePrompt ? "Codex 设备码登录超时，请重试" : "Codex 浏览器登录超时，请重试")
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
                throw ProviderError.loginIncomplete(tool: .codex, message: "Codex 登录未完成，请在浏览器完成授权后重试")
            }
            throw ProviderError.loginIncomplete(tool: .codex, message: "Codex 登录失败：\(output)")
        }

        throw ProviderError.missingFile(path: scratchAuthPath)
    }

    func ensureFileCredentialStore(at configPath: String) throws {
        let current = (try? fileService.readText(at: configPath)) ?? ""
        let updated = current.upsertingTopLevelTOMLString(
            key: "cli_auth_credentials_store",
            value: "file"
        )
        guard updated != current else { return }
        try fileService.writeTextWithBackup(updated, to: configPath, backupBaseName: "config.toml")
    }

    func loginFailureMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description.strippingANSIControlSequences().singleLineCondensed(maxLength: 320)
        }
        return error.localizedDescription.strippingANSIControlSequences().singleLineCondensed(maxLength: 320)
    }

    @MainActor
    static func presentDeviceAuthPrompt(_ prompt: CodexDeviceAuthPrompt) {
        NSWorkspace.shared.open(prompt.url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt.code, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Codex 设备登录"
        alert.informativeText = "已打开登录页面，验证码已复制到剪贴板：\(prompt.code)"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    func readValidatedAuthIfAvailable(at path: String) throws -> String? {
        guard fileService.fileExists(at: path) else { return nil }
        let auth = try fileService.readText(at: path)
        guard let data = auth.data(using: .utf8) else {
            throw ProviderError.credentialParsingFailed(tool: .codex)
        }
        let credentials = try parseCredentials(data: data)
        if let accessToken = credentials.accessToken, !accessToken.isEmpty {
            return auth
        }
        if let apiKey = credentials.apiKey, !apiKey.isEmpty {
            return auth
        }
        throw ProviderError.noUsableCredential(tool: .codex)
    }

    func findCodexExecutable() -> URL? {
        let fileManager = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathCandidates = augmentedPath(from: ProcessInfo.processInfo.environment["PATH"])
            .split(separator: ":")
            .map { String($0) }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }

        let explicitCandidates = explicitCodexExecutableURLs(home: home)

        for url in pathCandidates + explicitCandidates {
            guard fileManager.isExecutableFile(atPath: url.path) else { continue }
            return url
        }

        return nil
    }

    func explicitCodexExecutableURLs(home: String) -> [URL] {
        [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.deno/bin/codex",
            "\(home)/.cargo/bin/codex",
            "\(home)/.volta/bin/codex"
        ].map(URL.init(fileURLWithPath:))
    }

    func augmentedPath(from currentPath: String?) -> String {
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

}
