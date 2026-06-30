import Foundation

extension ClaudeCodeProvider {
    func parseCredentials(_ secret: String) throws -> ClaudeCodeCredentials {
        guard let data = secret.data(using: .utf8) else {
            throw ProviderError.invalidCredentials
        }
        return try JSONDecoder().decode(ClaudeCodeCredentials.self, from: data)
    }

    func encodeCredentials(_ credentials: ClaudeCodeCredentials) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(credentials)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    func thirdPartyProviderName(credentials: ClaudeCodeCredentials, status: [String: Any]?) -> String? {
        let settings = credentials.claudeSettingsJSON.flatMap(parseJSONObject) as? [String: Any]
        if let env = settings?["env"] as? [String: Any] {
            if let baseURL = firstString(
                in: env,
                keys: ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_URL", "CLAUDE_BASE_URL"]
            ),
               let provider = providerName(fromBaseURL: baseURL) {
                return provider
            }

            if let model = firstString(
                in: env,
                keys: ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_MODEL", "CLAUDE_MODEL"]
            ),
               let provider = providerName(fromModel: model) {
                return provider
            }
        }

        if let provider = credentials.apiProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty,
           !isFirstPartyClaudeProvider(provider) {
            return displayProviderName(from: provider)
        }

        if let modelName = firstString(in: status as Any, keys: ["name", "display_name", "displayName", "model"]),
           let provider = providerName(fromModel: modelName) {
            return provider
        }

        return nil
    }

    func providerName(fromBaseURL raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let host = URL(string: trimmed)?.host ?? URL(string: "https://\(trimmed)")?.host
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        if host == "api.anthropic.com" || host.hasSuffix(".anthropic.com") || host.hasSuffix(".claude.ai") {
            return nil
        }
        if host == "xiaomimimo.com" || host.hasSuffix(".xiaomimimo.com") {
            return "Xiaomi Mimo"
        }
        return host
            .split(separator: ".")
            .prefix(2)
            .map { part in part.prefix(1).uppercased() + part.dropFirst() }
            .joined(separator: " ")
    }

    func providerName(fromModel raw: String) -> String? {
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !model.isEmpty else { return nil }
        if model.hasPrefix("mimo-") || model.contains("/mimo-") {
            return "Xiaomi Mimo"
        }
        return nil
    }

    func isFirstPartyClaudeProvider(_ provider: String?) -> Bool {
        guard let normalized = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return false
        }
        return [
            "firstparty",
            "first_party",
            "claude.ai",
            "claude",
            "anthropic",
            "anthropic.com",
            "api.anthropic.com"
        ].contains(normalized)
    }

    func displayProviderName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        if let mapped = providerName(fromBaseURL: trimmed) {
            return mapped
        }
        if let mapped = providerName(fromModel: trimmed) {
            return mapped
        }
        switch trimmed.lowercased() {
        case "firstparty", "first_party":
            return "Claude.ai"
        case "xiaomi", "mimo", "xiaomi_mimo", "xiaomi-mimo":
            return "Xiaomi Mimo"
        default:
            return trimmed
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}
