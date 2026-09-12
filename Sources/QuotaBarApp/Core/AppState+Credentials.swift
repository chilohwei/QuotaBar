import Foundation

extension AppState {
    func resolveSecret(for account: Account, provider: any Provider) async throws -> String {
        var recoveryError: Error?
        do {
            if let recovered = try await provider.recoverSecret(for: account),
               !recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return recovered
            }
        } catch {
            recoveryError = error
            if !shouldStoreSecretInKeychain(for: account.tool) {
                throw error
            }
        }

        guard shouldStoreSecretInKeychain(for: account.tool) else {
            throw recoveryError ?? SecretStoreError.missingData
        }

        do {
            return try secretStore.readSecret(accountKey: secretStoreKey(for: account.id))
        } catch SecretStoreError.missingData {
            if let recovered = try await provider.recoverSecret(for: account),
               !recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if shouldStoreSecretInKeychain(for: account.tool) {
                    try secretStore.saveSecret(recovered, accountKey: secretStoreKey(for: account.id))
                }
                return recovered
            }
            throw SecretStoreError.missingData
        }
    }

    // Claude Code identity keys used to be derived from `~/.claude.json`'s `userID`, which the
    // CLI mints once per installation and never rotates on login — every account on the machine
    // shared it, so adding a second account merged it into the first one's card. Re-key stored
    // accounts from their own secrets before the launch-time credential sync runs, or that sync
    // would fail to match the migrated aliases and create a duplicate card.
    func migrateLegacyClaudeIdentityKeys() async {
        let provider = provider(for: .claudeCode)
        var changed = false
        for index in accounts.indices where accounts[index].tool == .claudeCode {
            let currentKey = accounts[index].settings.identityKey?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized = currentKey?.lowercased(),
               normalized.hasPrefix("claude-code:account:") || normalized.hasPrefix("claude-code:email:") {
                continue
            }
            guard let secret = try? await resolveSecret(for: accounts[index], provider: provider),
                  let identity = provider.accountIdentity(from: secret)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !identity.isEmpty,
                  identity.lowercased() != currentKey?.lowercased() else {
                continue
            }
            let normalizedIdentity = identity.lowercased()
            guard normalizedIdentity.hasPrefix("claude-code:account:")
                || normalizedIdentity.hasPrefix("claude-code:email:") else {
                continue
            }
            accounts[index].settings.identityKey = identity
            changed = true
            AppLog.account.info("Migrated legacy Claude identity key for account \(self.accounts[index].id.uuidString, privacy: .public)")
        }
        if changed {
            try? await persistState()
        }
    }

    func findDuplicateStoredAccount(
        for tool: ToolKind,
        detectedIdentities: [String]
    ) -> Account? {
        let normalizedDetectedIdentities = Set(detectedIdentities.map(AccountIdentityResolver.normalizeIdentityName))
        guard !normalizedDetectedIdentities.isEmpty else { return nil }

        for account in accounts where account.tool == tool {
            if let storedIdentity = account.settings.identityKey.map(AccountIdentityResolver.normalizeIdentityName),
               normalizedDetectedIdentities.contains(storedIdentity) {
                return account
            }
        }

        return nil
    }

    /// Captures the installed account without changing QuotaBar's active selection. A deleted
    /// account may be intentionally discarded; any other untracked account is preserved first.
    func captureInstalledCurrentAccountBeforeReplacement(
        for tool: ToolKind,
        captureMissingAccount: Bool,
        discardedAccount: Account?
    ) async -> Bool {
        let provider = provider(for: tool)
        do {
            let secret = try await provider.importCurrentCredentials()
            guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  provider.canSafelyReplaceInstalledCredentials(afterImport: secret) else {
                return false
            }

            let aliases = provider.accountIdentityAliases(from: secret)
            let detectedIdentities = aliases.isEmpty
                ? provider.accountIdentity(from: secret).map { [$0] } ?? []
                : aliases
            let existing = findDuplicateStoredAccount(
                for: tool,
                detectedIdentities: detectedIdentities
            )
            if existing == nil, !captureMissingAccount {
                guard let discardedIdentity = discardedAccount?.settings.identityKey
                    .map(AccountIdentityResolver.normalizeIdentityName) else {
                    return false
                }
                let normalizedDetected = Set(
                    detectedIdentities.map(AccountIdentityResolver.normalizeIdentityName)
                )
                return normalizedDetected.contains(discardedIdentity)
            }

            _ = try await addAccount(
                tool: tool,
                name: "",
                secret: secret,
                makeActive: false,
                useAsDefaultActive: false,
                applyToTool: false,
                refreshAfterAdd: false
            )
            return true
        } catch {
            AppLog.account.error("Failed to capture installed \(tool.rawValue, privacy: .public) credentials before replacement: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// A statusLine event can arrive while its active Claude account is hidden for undo. Keep the
    /// captured token pair with that pending account, but never recreate or reactivate its row.
    func absorbCredentialSyncForPendingDeletion(
        tool: ToolKind,
        provider: any Provider,
        secret: String
    ) -> Bool {
        let aliases = provider.accountIdentityAliases(from: secret)
        let detectedIdentities = aliases.isEmpty
            ? provider.accountIdentity(from: secret).map { [$0] } ?? []
            : aliases
        if finalizingDeletionAccounts.values.contains(where: {
            $0.tool == tool
                && Self.accountIdentity($0.settings.identityKey, matchesAny: detectedIdentities)
        }) {
            return true
        }
        guard let pending = pendingDeletion,
              pending.account.tool == tool,
              Self.accountIdentity(
                  pending.account.settings.identityKey,
                  matchesAny: detectedIdentities
              ) else {
            return false
        }

        if shouldStoreSecretInKeychain(for: tool),
           provider.canSafelyReplaceInstalledCredentials(afterImport: secret) {
            var reconciledSecret = secret
            if let storedSecret = try? secretStore.readSecret(accountKey: secretStoreKey(for: pending.account.id)) {
                reconciledSecret = (try? provider.reconcileImportedSecret(
                    secret,
                    withStoredSecret: storedSecret
                )) ?? secret
            }
            do {
                try secretStore.saveSecret(
                    reconciledSecret,
                    accountKey: secretStoreKey(for: pending.account.id)
                )
            } catch {
                AppLog.account.error("Failed to update pending-deletion \(tool.rawValue, privacy: .public) credentials: \(String(describing: error), privacy: .private)")
            }
        }
        return true
    }

    static func accountIdentity(_ identity: String?, matchesAny candidates: [String]) -> Bool {
        guard let identity else { return false }
        let normalizedIdentity = AccountIdentityResolver.normalizeIdentityName(identity)
        return candidates
            .map(AccountIdentityResolver.normalizeIdentityName)
            .contains(normalizedIdentity)
    }

    func updateAccountIdentityIfNeeded(accountID: UUID, identity: String?) -> Bool {
        guard let identity = identity?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return false
        }

        let current = accounts[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != identity else { return false }

        let shouldPreferIdentity = AccountIdentityResolver.looksAutoGeneratedName(current, tool: accounts[index].tool)
            || (identity.contains("@") && !current.contains("@"))
            || current.isEmpty

        guard shouldPreferIdentity else { return false }
        accounts[index].name = identity
        return true
    }

    func updateAccountReadableNameIfNeeded(
        accountID: UUID,
        provider: any Provider,
        secret: String
    ) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return false
        }
        let current = accounts[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AccountIdentityResolver.looksAutoGeneratedName(current, tool: accounts[index].tool) || current.isEmpty else {
            return false
        }
        guard let detected = provider.suggestAccountName(from: secret)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detected.isEmpty,
              detected != current else {
            return false
        }
        accounts[index].name = detected
        return true
    }

    func updateAccountSettingsIfNeeded(
        accountID: UUID,
        provider: any Provider,
        secret: String
    ) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return false
        }
        guard let identity = provider.accountIdentity(from: secret)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty,
              accounts[index].settings.identityKey != identity else {
            return false
        }

        accounts[index].settings.identityKey = identity
        return true
    }
}
