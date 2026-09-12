import Foundation

struct Account: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let tool: ToolKind
    var name: String
    let createdAt: Date
    var settings: AccountSettings

    init(
        id: UUID = UUID(),
        tool: ToolKind,
        name: String,
        createdAt: Date = .init(),
        settings: AccountSettings = .empty
    ) {
        self.id = id
        self.tool = tool
        self.name = name
        self.createdAt = createdAt
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tool
        case name
        case createdAt
        case settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tool = try container.decode(ToolKind.self, forKey: .tool)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        settings = try container.decodeIfPresent(AccountSettings.self, forKey: .settings) ?? .empty
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tool, forKey: .tool)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(settings, forKey: .settings)
    }
}
