import Foundation

/// Monetary usage is a cost, not a request quota or purchased credit balance.
struct QuotaSpend: Codable, Equatable, Sendable {
    let label: String
    let used: Double
    let limit: Double?
    let currency: String
    let resetAt: Date?
}
