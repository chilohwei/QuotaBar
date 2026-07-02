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
    // `/api/oauth/usage` is aggressively rate-limited (see anthropics/claude-code#30930); the
    // community-recommended floor for polling it is ~180s, so we stay at or above that.
    static let liveUsageMinFetchInterval: TimeInterval = 180
    // When the OAuth fallback path is temporarily unavailable, the last live snapshot may be shown
    // up to this old, clearly labeled with its age.
    static let liveUsageStaleMax: TimeInterval = 30 * 60
    // After a token refresh fails, wait this long before trying again, so a throttled auth endpoint
    // is given room to recover instead of being hammered on every poll cycle. This is the *base*
    // cooldown: consecutive failures escalate it (5 → 10 → 20 → 30 min) up to `tokenRefreshCooldownMax`,
    // because the auth endpoint returns a misleading `retry-after: 0` on 429 and a fixed short retry
    // only sustains the rate limit (see anthropics/claude-code#30930).
    static let tokenRefreshCooldown: TimeInterval = 5 * 60
    static let tokenRefreshCooldownMax: TimeInterval = 30 * 60
    static let rateLimitTranscriptLookback: TimeInterval = 24 * 60 * 60
    static let recentTranscriptFileLimit = 16
    static let transcriptTailByteLimit: UInt64 = 512 * 1024
    static let rateLimitWithoutResetFreshness: TimeInterval = 10 * 60
    static let fiveHourLimitKeys: Set<String> = [
        "five_hour",
        "fiveHour",
        "five_hour_limit",
        "fiveHourLimit",
        "five_hour_usage",
        "fiveHourUsage",
        "5h"
    ]
    static let weeklyLimitKeys: Set<String> = [
        "seven_day",
        "sevenDay",
        "seven_day_limit",
        "sevenDayLimit",
        "seven_day_usage",
        "sevenDayUsage",
        "seven_day_all_models",
        "sevenDayAllModels",
        "weekly",
        "week",
        "weekly_limit",
        "weeklyLimit",
        "weekly_usage",
        "weeklyUsage",
        "weekly_all_models",
        "weeklyAllModels",
        "7d"
    ]
    // Canonical (Simplified) note strings live in `QuotaNoteCatalog`; the UI localizes them at render
    // time via `AppText.localizedNote`. These aliases keep call sites readable.
    static let rateLimitReachedNote = QuotaNoteCatalog.claudeRateLimitReached
    // Shown when the OAuth fallback `/usage`/token endpoints are throttling us (HTTP 429). Tells
    // the user it will self-recover and how to force a fix if it lingers.
    static let usageRateLimitedNote = QuotaNoteCatalog.claudeUsageRateLimited
    // How long a `/usage` 429 keeps signalling "rate limited" for the note, absent a fresh success.
    static let usageRateLimitMarkerFreshness: TimeInterval = 30 * 60
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
