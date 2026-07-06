import CryptoKit
import Foundation

struct ClaudeCodeProvider: Provider {
    let tool: ToolKind = .claudeCode

    static let oauthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let oauthTokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let oauthUsageUserAgent = "claude-code/2.1.181"
    // How long a hard-expired keychain token must sit untouched before QuotaBar renews it itself
    // (see ClaudeCodeProvider+TokenRefresh). Any actively used CLI refreshes its token within
    // seconds of the first API call past expiry, so a token still expired after this window has
    // no other maintainer — GUI clients like the Claude desktop app keep their own credential
    // store and never renew this keychain item.
    static let selfRefreshGrace: TimeInterval = 10 * 60
    // Floor between self-refresh attempts after a transient failure (network, 5xx, throttling).
    static let selfRefreshRetryFloor: TimeInterval = 10 * 60
    // Floor after the server declared the refresh token dead (invalid_grant): only a fresh
    // Claude Code login can mint a new pair, so retrying sooner is pure noise.
    static let selfRefreshDeadGrantRetryFloor: TimeInterval = 24 * 60 * 60
    // Floor between real `/usage` network calls per account. Bursty triggers (panel open, foreground,
    // statusLine change) within this window reuse the last live snapshot instead of re-hitting the
    // endpoint, which keeps QuotaBar from tripping the endpoint's own per-account rate limit.
    // `/api/oauth/usage` is aggressively rate-limited (see anthropics/claude-code#30930); the
    // community-recommended floor for polling it is ~180s, so we stay at or above that.
    static let liveUsageMinFetchInterval: TimeInterval = 180
    // When live usage is temporarily unavailable, the last live snapshot may be shown up to this
    // old, clearly labeled with its age.
    static let liveUsageStaleMax: TimeInterval = 30 * 60
    // Cached OAuth data older than this no longer fills gaps in the statusLine snapshot;
    // day-old numbers presented next to live ones mislead more than they inform.
    static let historicalFillMaxAge: TimeInterval = 24 * 60 * 60
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
