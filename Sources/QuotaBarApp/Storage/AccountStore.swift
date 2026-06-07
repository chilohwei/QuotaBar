import Foundation

struct PersistedState: Codable {
    var accounts: [Account]
    var activeAccountByTool: [ToolKind: UUID]

    static let empty = PersistedState(accounts: [], activeAccountByTool: [:])

    private enum CodingKeys: String, CodingKey {
        case accounts
        case activeAccountByTool
    }

    init(accounts: [Account], activeAccountByTool: [ToolKind: UUID]) {
        self.accounts = accounts
        self.activeAccountByTool = activeAccountByTool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossyAccounts = try container.decodeIfPresent([LossyAccount].self, forKey: .accounts) ?? []
        accounts = lossyAccounts.compactMap(\.account)

        activeAccountByTool = try Self.decodeActiveAccounts(from: container)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accounts, forKey: .accounts)
        let rawActiveAccounts = activeAccountByTool.reduce(into: [String: UUID]()) { result, item in
            result[item.key.rawValue] = item.value
        }
        try container.encode(rawActiveAccounts, forKey: .activeAccountByTool)
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
