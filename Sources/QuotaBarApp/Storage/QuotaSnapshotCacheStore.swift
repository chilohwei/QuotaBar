import Foundation

struct QuotaSnapshotCacheStore: Sendable {
    private let fileService = FileService()

    func load(accountID: UUID, tool: ToolKind) throws -> QuotaSnapshot {
        let text = try fileService.readText(at: cachePath(accountID: accountID))
        guard let data = text.data(using: .utf8) else {
            throw ProviderError.cacheCorrupted(tool: tool)
        }
        return try JSONDecoder().decode(QuotaSnapshot.self, from: data)
    }

    func load(accountID: UUID) throws -> QuotaSnapshot {
        try load(accountID: accountID, tool: .codex)
    }

    func save(_ snapshot: QuotaSnapshot, accountID: UUID) throws {
        try fileService.createDirectoryIfNeeded(at: AppPaths.accountQuotaSnapshotsDirectory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try fileService.writeText(
            String(data: data, encoding: .utf8) ?? "{}",
            to: cachePath(accountID: accountID),
            permissions: 0o600
        )
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
