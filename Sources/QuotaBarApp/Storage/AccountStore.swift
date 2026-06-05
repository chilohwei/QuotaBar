import Foundation

struct PersistedState: Codable {
    var accounts: [Account]
    var activeAccountByTool: [ToolKind: UUID]
    var lowQuotaThreshold: Double

    static let empty = PersistedState(accounts: [], activeAccountByTool: [:], lowQuotaThreshold: 0.15)

    private enum CodingKeys: String, CodingKey {
        case accounts
        case activeAccountByTool
        case lowQuotaThreshold
    }

    init(accounts: [Account], activeAccountByTool: [ToolKind: UUID], lowQuotaThreshold: Double) {
        self.accounts = accounts
        self.activeAccountByTool = activeAccountByTool
        self.lowQuotaThreshold = lowQuotaThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossyAccounts = try container.decodeIfPresent([LossyAccount].self, forKey: .accounts) ?? []
        accounts = lossyAccounts.compactMap(\.account)

        activeAccountByTool = try Self.decodeActiveAccounts(from: container)
        lowQuotaThreshold = try container.decodeIfPresent(Double.self, forKey: .lowQuotaThreshold) ?? 0.15
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accounts, forKey: .accounts)
        let rawActiveAccounts = activeAccountByTool.reduce(into: [String: UUID]()) { result, item in
            result[item.key.rawValue] = item.value
        }
        try container.encode(rawActiveAccounts, forKey: .activeAccountByTool)
        try container.encode(lowQuotaThreshold, forKey: .lowQuotaThreshold)
    }

    private static func decodeActiveAccounts(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [ToolKind: UUID] {
        if let rawActiveAccounts = try? container.decode([String: UUID].self, forKey: .activeAccountByTool) {
            return rawActiveAccounts.reduce(into: [:]) { result, item in
                guard let tool = ToolKind(rawValue: item.key) else { return }
                result[tool] = item.value
            }
        }

        let legacyPairs = try container.decodeIfPresent([String].self, forKey: .activeAccountByTool) ?? []
        var decoded: [ToolKind: UUID] = [:]
        var index = legacyPairs.startIndex
        while index < legacyPairs.endIndex {
            let nextIndex = legacyPairs.index(after: index)
            guard nextIndex < legacyPairs.endIndex else { break }
            if let tool = ToolKind(rawValue: legacyPairs[index]),
               let accountID = UUID(uuidString: legacyPairs[nextIndex]) {
                decoded[tool] = accountID
            }
            index = legacyPairs.index(after: nextIndex)
        }
        return decoded
    }
}

private struct LossyAccount: Decodable {
    let account: Account?

    init(from decoder: Decoder) throws {
        account = try? Account(from: decoder)
    }
}

actor AccountStore {
    nonisolated static func loadImmediately() throws -> PersistedState {
        try loadPersistedState()
    }

    func load() throws -> PersistedState {
        try Self.loadPersistedState()
    }

    private nonisolated static func loadPersistedState() throws -> PersistedState {
        try AppPaths.ensureDirectories()
        guard FileManager.default.fileExists(atPath: AppPaths.accountsFile.path) else {
            return .empty
        }

        let data = try Data(contentsOf: AppPaths.accountsFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) throws {
        try AppPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: AppPaths.accountsFile, options: .atomic)
    }
}
