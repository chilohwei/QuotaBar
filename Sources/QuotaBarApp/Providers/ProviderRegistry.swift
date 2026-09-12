import Foundation

struct ProviderRegistry: Sendable {
    let supportedTools: [ToolKind] = [.codex, .cursor, .claudeCode]
    private let overrides: [ToolKind: any Provider]

    init(overrides: [ToolKind: any Provider] = [:]) {
        self.overrides = overrides
    }

    func provider(for tool: ToolKind) -> any Provider {
        if let override = overrides[tool] {
            return override
        }
        switch tool {
        case .codex:
            return CodexProvider()
        case .cursor:
            return CursorProvider()
        case .claudeCode:
            return ClaudeCodeProvider()
        }
    }
}
