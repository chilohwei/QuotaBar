import Foundation

extension CodexProvider {
    func registryAccountKey(from secret: String) -> String? {
        guard let data = secret.data(using: .utf8),
              let credentials = try? parseCredentials(data: data) else {
            return nil
        }
        return extractIdentity(fromIDToken: credentials.idToken).accountKey
    }

    func registryAuthSnapshotPath(accountKey: String) -> String {
        "\(accountsDirectoryPath)/\(registryFileKey(for: accountKey)).auth.json"
    }

    func registryFileKey(for accountKey: String) -> String {
        guard keyNeedsFilenameEncoding(accountKey) else {
            return accountKey
        }
        return Data(accountKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func keyNeedsFilenameEncoding(_ key: String) -> Bool {
        guard !key.isEmpty, key != ".", key != ".." else {
            return true
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return key.unicodeScalars.contains { !allowed.contains($0) }
    }

    func upsertRegistryAccount(account: Account, secret: String, makeActive: Bool) throws {
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
            backupBaseName: "\(registryFileKey(for: accountKey)).auth.json",
            permissions: 0o600
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

    func removeRegistryAccount(accountKey: String) throws {
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
            backupBaseName: "\(registryFileKey(for: accountKey)).auth.json",
            permissions: 0o600
        )
        try fileService.removeItemIfExists(at: registryAuthSnapshotPath(accountKey: accountKey))
    }

    struct RegistryAccountMetadata {
        let chatGPTAccountID: String?
        let email: String?
        let planName: String?
        let billingCycle: String?
    }

    func normalizedRegistryKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    func loadRegistryAccountMetadata(accountKey: String) -> RegistryAccountMetadata? {
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
}
