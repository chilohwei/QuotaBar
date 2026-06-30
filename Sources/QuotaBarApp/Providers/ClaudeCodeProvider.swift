import CryptoKit
import Foundation

struct ClaudeCodeProvider: Provider {
    let tool: ToolKind = .claudeCode

    static let oauthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let oauthTokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let oauthUsageUserAgent = "claude-code/2.1.181"
    // Refresh the access token this long before its stored expiry, so `/usage` calls never go out
    // with an already-dead token.
    static let oauthTokenExpiryMargin: TimeInterval = 2 * 60
    // Floor between real `/usage` network calls per account. Bursty triggers (panel open, foreground,
    // statusLine change) within this window reuse the last live snapshot instead of re-hitting the
    // endpoint, which keeps QuotaBar from tripping the endpoint's own per-account rate limit.
    static let liveUsageMinFetchInterval: TimeInterval = 60
    // When `/usage` is temporarily unavailable, the last live snapshot may be shown — clearly
    // labeled with its age — up to this old, instead of falling back to stale statusLine data.
    static let liveUsageStaleMax: TimeInterval = 30 * 60
    // After a token refresh fails, wait this long before trying again, so a throttled auth endpoint
    // is given room to recover instead of being hammered on every poll cycle.
    static let tokenRefreshCooldown: TimeInterval = 5 * 60
    static let rateLimitTranscriptLookback: TimeInterval = 24 * 60 * 60
    static let recentTranscriptFileLimit = 16
    static let transcriptTailByteLimit: UInt64 = 512 * 1024
    static let rateLimitWithoutResetFreshness: TimeInterval = 10 * 60
    static let rateLimitReachedNote =
        "Claude Code 已提示 Usage limit reached；QuotaBar 在重置前按 0% 剩余额度显示。"
    static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    let fileService = FileService()

    struct ClaudeCodeCredentials: Codable {
        let loggedIn: Bool
        let authMethod: String?
        let apiProvider: String?
        let userID: String?
        let claudeExecutablePath: String?
        let keychainCredentials: String?
        let authStatusJSON: String?
        let claudeSettingsJSON: String?
        let claudeJSON: String?
        let claudeCredentialsJSON: String?
        let claudeAuthJSON: String?
    }

}
