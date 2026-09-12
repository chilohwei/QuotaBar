import Foundation

extension CodexProvider {
    func resolveUsageURL(codexHomePath: String?) -> URL {
        let fallback = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let configuredBase: String?
        if let codexHomePath {
            configuredBase = try? String(contentsOfFile: "\(codexHomePath)/config.toml", encoding: .utf8)
                .flatMapChatGPTBaseURL()
        } else if let activeConfig = try? fileService.readText(at: activeConfigPath) {
            configuredBase = activeConfig.flatMapChatGPTBaseURL()
        } else {
            configuredBase = nil
        }

        var base = configuredBase?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "https://chatgpt.com/backend-api"
        while base.hasSuffix("/") {
            base.removeLast()
        }

        guard let baseURL = URL(string: base),
              Self.isTrustedOAuthUsageHost(baseURL.host) else {
            if configuredBase != nil {
                AppLog.refresh.warning("Ignoring non-official Codex chatgpt_base_url for OAuth usage request")
            }
            return fallback
        }

        if (base.hasPrefix("https://chatgpt.com") || base.hasPrefix("https://chat.openai.com")),
           !base.contains("/backend-api") {
            base += "/backend-api"
        }

        let path = base.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        return URL(string: base + path) ?? fallback
    }

    static func isTrustedOAuthUsageHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
            || host == "chat.openai.com"
            || host.hasSuffix(".chat.openai.com")
    }

    func resolveSubscriptionURL(codexHomePath: String?) -> URL {
        let usageURL = resolveUsageURL(codexHomePath: codexHomePath)
        let absolute = usageURL.absoluteString
        if absolute.hasSuffix("/wham/usage") {
            return URL(string: String(absolute.dropLast("/wham/usage".count)) + "/subscriptions")
                ?? URL(string: "https://chatgpt.com/backend-api/subscriptions")!
        }
        if absolute.hasSuffix("/api/codex/usage") {
            return URL(string: String(absolute.dropLast("/api/codex/usage".count)) + "/api/codex/subscriptions")
                ?? URL(string: "https://chatgpt.com/backend-api/subscriptions")!
        }
        return URL(string: "https://chatgpt.com/backend-api/subscriptions")!
    }
}
