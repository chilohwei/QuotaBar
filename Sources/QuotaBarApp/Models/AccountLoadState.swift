import Foundation

enum AccountLoadState: String, Codable, Equatable, Sendable {
    case idle
    case loadingInitial
    case refreshing
    case loaded
    case stale
    case failed
}
