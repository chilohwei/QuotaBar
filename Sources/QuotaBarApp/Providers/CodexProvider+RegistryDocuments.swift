import Foundation

extension CodexProvider {
    func loadRegistryDocument() throws -> CodexRegistryDocument {
        guard fileService.fileExists(at: registryPath) else {
            return .empty
        }
        let text = try fileService.readText(at: registryPath)
        guard let data = text.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
        }
        return try JSONDecoder().decode(CodexRegistryDocument.self, from: data)
    }

    func saveRegistryDocument(_ registry: CodexRegistryDocument) throws {
        try fileService.createDirectoryIfNeeded(at: accountsDirectoryPath)
        var normalized = registry
        normalized.schemaVersion = CodexRegistrySchema.currentVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try fileService.writeTextWithBackup(text, to: registryPath, backupBaseName: "registry.json", permissions: 0o600)
    }

    func updateStoredUsage(
        _ snapshot: QuotaSnapshot,
        accountKey: String?,
        accountID: String?,
        email: String?
    ) throws {
        guard let accountKey = normalizedRegistryKey(accountKey),
              fileService.fileExists(at: registryPath) else {
            return
        }

        var registry = try loadRegistryDocument()
        guard let index = registry.accounts.firstIndex(where: { $0.accountKey == accountKey }) else {
            return
        }

        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedEmail?.isEmpty == false {
            registry.accounts[index].email = normalizedEmail
        }
        if let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            registry.accounts[index].chatGPTAccountID = accountID
        }
        registry.accounts[index].lastUsage = CodexStoredUsageSnapshot(snapshot: snapshot)
        registry.accounts[index].lastUsageAt = Int64(snapshot.updatedAt.timeIntervalSince1970)
        if let planType = registry.accounts[index].lastUsage?.planType,
           planType != "unknown" {
            registry.accounts[index].plan = planType
        }

        try saveRegistryDocument(registry)
    }

    func loadJSONDictionary(at path: String) throws -> [String: Any] {
        let text = try fileService.readText(at: path)
        guard let data = text.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidCredentials
        }
        return dict
    }

    func writeJSONDictionary(_ dict: [String: Any], to path: String, backup: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let text = String(data: data, encoding: .utf8) ?? "{}"
        if backup {
            try fileService.writeTextWithBackup(
                text,
                to: path,
                backupBaseName: URL(fileURLWithPath: fileService.expand(path: path)).lastPathComponent,
                permissions: 0o600
            )
        } else {
            try fileService.writeText(text, to: path, permissions: 0o600)
        }
    }
}
