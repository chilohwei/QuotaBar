import Foundation

extension CodexProvider {
    func quotaCacheKey(
        accountKey: String?,
        accountID: String?,
        fallbackAccountIdentifier: String?
    ) -> String? {
        let raw = [accountKey, accountID, fallbackAccountIdentifier]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let raw else { return nil }

        return Data(raw.lowercased().utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func quotaCachePath(cacheKey: String) -> String {
        AppPaths.quotaCacheDirectory.appendingPathComponent("\(cacheKey).json").path
    }

    func loadCachedQuotaSnapshot(cacheKey: String) throws -> CachedQuotaSnapshot {
        let text = try fileService.readText(at: quotaCachePath(cacheKey: cacheKey))
        guard let data = text.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
        }
        return try JSONDecoder().decode(CachedQuotaSnapshot.self, from: data)
    }

    func storeQuotaSnapshot(_ snapshot: QuotaSnapshot, cacheKey: String) throws {
        try fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        let cached = CachedQuotaSnapshot(
            schemaVersion: 1,
            cachedAt: .init(),
            snapshot: snapshot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cached)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try fileService.writeText(text, to: quotaCachePath(cacheKey: cacheKey), permissions: 0o600)
    }

    func mergedNote(_ existing: String?, fallback: String) -> String {
        guard let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines),
              !existing.isEmpty else {
            return fallback
        }
        if existing.contains(fallback) {
            return existing
        }
        return "\(existing)；\(fallback)"
    }
}
