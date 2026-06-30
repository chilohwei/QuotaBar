import Foundation

extension CodexProvider {
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
        try fileService.writeTextWithBackup(secret, to: "\(managedHome)/auth.json", backupBaseName: "auth.json", permissions: 0o600)
        try upsertRegistryAccount(account: updated, secret: secret, makeActive: false)

        return updated
    }

    func activate(account: Account, secret: String) async throws {
        guard secret.data(using: .utf8) != nil else {
            throw ProviderError.invalidCredentials
        }

        let managedHome = account.settings.codexHomePath ?? AppPaths.managedCodexHomePath(accountID: account.id)
        try fileService.createDirectoryIfNeeded(at: managedHome)

        try fileService.writeTextWithBackup(secret, to: activeAuthPath, backupBaseName: "auth.json", permissions: 0o600)
        try fileService.writeTextWithBackup(secret, to: "\(managedHome)/auth.json", backupBaseName: "auth.json", permissions: 0o600)
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

    enum SecretRecoverySource {
        case managed
        case registrySnapshot
        case activeGlobal
    }

    func recoveredSecretMatches(_ secret: String, account: Account, source: SecretRecoverySource) -> Bool {
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

    func normalizedIdentity(_ identity: String) -> String {
        identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

}
