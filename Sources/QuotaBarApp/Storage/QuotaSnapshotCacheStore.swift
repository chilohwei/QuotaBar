import Foundation

struct QuotaSnapshotCacheStore: Sendable {
    private let fileService = FileService()

    func load(accountID: UUID) throws -> QuotaSnapshot {
        let text = try fileService.readText(at: cachePath(accountID: accountID))
        guard let data = text.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
        }
        return try JSONDecoder().decode(QuotaSnapshot.self, from: data)
    }

    func save(_ snapshot: QuotaSnapshot, accountID: UUID) throws {
        try fileService.createDirectoryIfNeeded(at: AppPaths.accountQuotaSnapshotsDirectory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try fileService.writeText(
            String(data: data, encoding: .utf8) ?? "{}",
            to: cachePath(accountID: accountID)
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cachePath(accountID: accountID))
    }

    func delete(accountID: UUID) throws {
        try fileService.removeItemIfExists(at: cachePath(accountID: accountID))
    }

    private func cachePath(accountID: UUID) -> String {
        AppPaths.accountQuotaSnapshotsDirectory
            .appendingPathComponent("\(accountID.uuidString).json")
            .path
    }
}
