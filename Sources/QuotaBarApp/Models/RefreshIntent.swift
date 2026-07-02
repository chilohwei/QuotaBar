enum RefreshIntent: String, Sendable {
    case background
    case visible
    case manual

    var bypassesProviderCache: Bool {
        self == .manual
    }

    var bypassesAppBackoff: Bool {
        self == .manual
    }
}
