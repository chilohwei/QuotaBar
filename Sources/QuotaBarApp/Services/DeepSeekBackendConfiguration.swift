import Foundation

struct DeepSeekBackendConfiguration: Sendable {
    let apiKey: String?

    static func read(for tool: ToolKind) -> Self? {
        let environment = ProcessInfo.processInfo.environment
        switch tool {
        case .codex:
            guard let config = try? FileService().readText(at: CodexProvider().activeConfigPath) else { return nil }
            return codex(config, environment: environment)
        case .claudeCode:
            let path = environment["CLAUDE_CONFIG_DIR"].flatMap(nonempty).map {
                URL(fileURLWithPath: FileService().expand(path: $0)).appendingPathComponent("settings.json")
            } ?? ClaudeCodeProvider().claudeSettingsURL()
            let settings = try? Data(contentsOf: path)
            return claude(settings, environment: environment)
        case .cursor, .deepSeek:
            return nil
        }
    }

    static func codex(_ config: String, environment: [String: String]) -> Self? {
        var tables: [[String]: [String: String]] = [:]
        var section: [String] = []
        var multilineDelimiter: String?
        let fieldNames = ["model_provider", "profile", "base_url", "env_key", "experimental_bearer_token"]
        for line in config.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let delimiter = multilineDelimiter {
                if trimmed.contains(delimiter) { multilineDelimiter = nil }
                continue
            }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if trimmed.hasPrefix("[") {
                let header = trimmed.split(separator: "#", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
                guard header.hasSuffix("]"), !header.hasPrefix("[[") else {
                    section = ["#unsupported"]
                    continue
                }
                section = header.dropFirst().dropLast().split(separator: ".").map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                if tables[section] == nil { tables[section] = [:] }
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if let delimiter = ["\"\"\"", "'''"].first(where: { value.hasPrefix($0) }) {
                if !value.dropFirst(3).contains(delimiter) { multilineDelimiter = delimiter }
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard fieldNames.contains(key) else { continue }
            let match = value.wholeMatch(of: /(?:"([^"\\]*)"|'([^']*)')\s*(?:#.*)?/)
            tables[section, default: [:]][key] = match.map { String($0.1 ?? $0.2 ?? "") } ?? ""
        }

        let root = tables[[]] ?? [:]
        let profile = root["profile"].flatMap { tables[["profiles", $0]] }
        if root["profile"] != nil, profile == nil { return nil }
        guard let provider = profile?["model_provider"] ?? root["model_provider"],
              let values = tables[["model_providers", provider]],
              isOfficialEndpoint(values["base_url"], allowedPaths: ["", "/v1"]) else { return nil }
        let key = values["experimental_bearer_token"].flatMap(nonempty)
            ?? values["env_key"].flatMap { environment[$0] }.flatMap(nonempty)
        return Self(apiKey: key)
    }

    static func claude(_ settings: Data?, environment: [String: String]) -> Self? {
        var configured: [String: Any] = [:]
        if let settings {
            guard let object = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any] else {
                return nil
            }
            configured = object["env"] as? [String: Any] ?? [:]
        }
        func value(_ name: String) -> String? {
            ((configured[name] as? String) ?? environment[name]).flatMap(nonempty)
        }
        guard isOfficialEndpoint(value("ANTHROPIC_BASE_URL"), allowedPaths: ["/anthropic"]) else { return nil }
        return Self(apiKey: value("ANTHROPIC_AUTH_TOKEN") ?? value("ANTHROPIC_API_KEY"))
    }

    private static func isOfficialEndpoint(_ value: String?, allowedPaths: Set<String>) -> Bool {
        guard let value, let url = URLComponents(string: value),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.deepseek.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        let path = url.percentEncodedPath
        return allowedPaths.contains(path.hasSuffix("/") ? String(path.dropLast()) : path)
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
