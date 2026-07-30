enum RefreshIntent: String, Sendable {
    case background
    case visible
    case manual
    case local

    var bypassesProviderCache: Bool {
        self == .manual
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
