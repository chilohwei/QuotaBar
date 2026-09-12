import Foundation

enum RefreshIntent: String, Sendable {
    case background
    case visible
    /// The user just opened the panel. Deliberate "show me now" moment, so it gets a much
    /// shorter provider-cache floor than the periodic traffic — but not none: see
    /// `providerCacheFloorOverride`.
    case dashboardOpen
    case manual
    case local

    var bypassesProviderCache: Bool {
        self == .manual
    }

    /// Shortens (never removes) how long a provider may reuse its own cached payload.
    ///
    /// Opening the panel must not translate into an unconditional network call. Anthropic's
    /// `/api/oauth/usage` rate-limits hard enough that tools polling it every 30–60s get stuck in a
    /// permanent 429 loop (anthropics/claude-code#30930, #31021, #31637) — at which point the panel
    /// shows *older* data than it would have with a floor. One live fetch per minute of panel
    /// opening is the freshness the user asked for without walking into that trap; "刷新" still
    /// bypasses the floor entirely via `bypassesProviderCache`.
    var providerCacheFloorOverride: TimeInterval? {
        self == .dashboardOpen ? 60 : nil
    }

    var bypassesAppBackoff: Bool {
        self == .manual || self == .local
    }

    var allowsProviderCredentialRefresh: Bool {
        self != .local
    }

    var preservesAppBackoffAfterSuccess: Bool {
        self == .local
    }
}
