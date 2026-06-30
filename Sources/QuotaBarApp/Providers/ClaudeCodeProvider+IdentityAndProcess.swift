import CryptoKit
import Foundation

extension ClaudeCodeProvider {
    func mergeCredentials(
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

    func claudeCredentialsRepresentSameAccount(
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

    func shouldClearStatusLineSnapshot(
        previous: ClaudeCodeCredentials?,
        next: ClaudeCodeCredentials
    ) -> Bool {
        guard let previous, previous.loggedIn else { return true }
        return !claudeCredentialsRepresentSameAccount(previous, next)
    }

    func legacyIdentity(from credentials: ClaudeCodeCredentials) -> String {
        let method = credentials.authMethod?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return "claude-code:\(method):\(provider)".lowercased()
    }

    func normalizeIdentityKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func stableCredentialFingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    func uniqueIdentityAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        return aliases.filter { alias in
            seen.insert(normalizeIdentityKey(alias)).inserted
        }
    }

    func runProcess(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> String {
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
