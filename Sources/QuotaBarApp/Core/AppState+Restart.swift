import Foundation

extension AppState {
    func scheduleActiveSelectionReassertion(for tool: ToolKind) {
        // Claude Code has no app to restart, and its credentials live in a shared keychain entry
        // guarded by the activation transaction — re-writing them here would race that.
        guard tool != .claudeCode, let account = activeAccount(for: tool) else { return }

        let token = UUID()
        restartReassertionTasks[tool]?.cancel()
        restartReassertionByTool[tool] = PendingRestartReassertion(accountID: account.id, token: token)
        restartReassertionTasks[tool] = Task { [weak self] in
            await self?.reassertActiveSelectionAfterRestart(for: tool, account: account)
            await MainActor.run {
                guard let self, self.restartReassertionByTool[tool]?.token == token else { return }
                self.restartReassertionByTool.removeValue(forKey: tool)
                self.restartReassertionTasks.removeValue(forKey: tool)
            }
        }
    }

    func reassertActiveSelectionAfterRestart(for tool: ToolKind, account: Account) async {
        let provider = provider(for: tool)
        var didReassert = false

        for checkpoint in restartReassertionCheckpoints {
            try? await Task.sleep(nanoseconds: UInt64(checkpoint * 1_000_000_000))
            guard !Task.isCancelled, activeAccountByTool[tool] == account.id else { return }

            guard let installed = try? await provider.importCurrentCredentials(),
                  !installed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !installedCredentials(installed, belongTo: account, provider: provider) else {
                continue
            }

            do {
                let secret = try await resolveSecret(for: account, provider: provider)
                try await provider.activate(account: account, secret: secret)
                // Our own write must not read back as an external account change.
                credentialSignatureByTool[tool] = credentialEventSignature(secret: secret, provider: provider)
                didReassert = true
                AppLog.account.info("Restarted \(tool.rawValue, privacy: .public) came back on a different account; restored \(account.id.uuidString, privacy: .public)")
            } catch {
                AppLog.account.error("Failed to restore \(account.id.uuidString, privacy: .public) after \(tool.rawValue, privacy: .public) restart: \(String(describing: error), privacy: .private)")
                return
            }
        }

        if didReassert {
            await refreshQuota(for: account, intent: .manual)
        }
    }

    /// True when the tool's installed credentials still describe `account`. Accounts stored before
    /// identity metadata existed carry no key; treat those as a match so the re-assertion stays
    /// silent instead of rewriting credentials it cannot actually verify.
    func installedCredentials(
        _ secret: String,
        belongTo account: Account,
        provider: any Provider
    ) -> Bool {
        guard account.settings.identityKey != nil else { return true }
        let aliases = provider.accountIdentityAliases(from: secret)
        let detected = aliases.isEmpty
            ? provider.accountIdentity(from: secret).map { [$0] } ?? []
            : aliases
        guard !detected.isEmpty else { return true }
        return Self.accountIdentity(account.settings.identityKey, matchesAny: detected)
    }
}
