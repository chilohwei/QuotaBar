import AppKit
import Foundation

final class LoginOutputBuffer: @unchecked Sendable {
    let lock = NSLock()
    var text = ""

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CodexLoginAttempt: Sendable {
    let name: String
    let arguments: [String]
    let timeout: TimeInterval
    let opensDevicePrompt: Bool
}

struct CodexImportedAccount: Sendable {
    let name: String
    let secret: String
    let isActive: Bool
}

struct CodexProvider: Provider {
    let tool: ToolKind = .codex
    let treatsImportedCredentialsAsActiveSelection = true
    let fileService = FileService()

    var codexHomePath: String {
        if let raw = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        return "~/.codex"
    }

    var activeAuthPath: String {
        "\(codexHomePath)/auth.json"
    }

    var activeConfigPath: String {
        "\(codexHomePath)/config.toml"
    }

    var accountsDirectoryPath: String {
        "\(codexHomePath)/accounts"
    }

    var registryPath: String {
        "\(accountsDirectoryPath)/registry.json"
    }

    var subscriptionsCachePath: String {
        "\(accountsDirectoryPath)/subscriptions.json"
    }

    let refreshClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    let tokenRefreshInterval: TimeInterval = 8 * 24 * 60 * 60
    let tokenRefreshLeeway: TimeInterval = 10 * 60
    let chatGPTUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"

    static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    static let fallbackQuotaCacheAge: TimeInterval = 24 * 60 * 60
    static let maxNetworkAttempts = 3
    static let httpClient = QuotaHTTPClient(session: liveSession, maxAttempts: maxNetworkAttempts)

    struct CachedQuotaSnapshot: Codable {
        let schemaVersion: Int
        let cachedAt: Date
        let snapshot: QuotaSnapshot
    }

}
