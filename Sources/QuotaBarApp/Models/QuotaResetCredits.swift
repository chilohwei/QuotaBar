import Foundation

/// Read-only reset inventory, separate from spendable balance and usage windows.
struct QuotaResetCredits: Codable, Equatable, Sendable {
    struct Credit: Codable, Equatable, Sendable {
        let expiresAt: Date?
    }

    let availableCount: Int
    let credits: [Credit]
    let updatedAt: Date

    func remainingCount(at now: Date) -> Int {
        // Only subtract expiries crossed since this response; the server count already
        // excludes credits expired before the response. Never infer missing inventory.
        max(0, availableCount - credits.filter {
            guard let expiry = $0.expiresAt else { return false }
            return expiry > updatedAt && expiry <= now
        }.count)
    }

    func availableCredits(at now: Date) -> [Credit] {
        credits.filter { $0.expiresAt.map { $0 > now } ?? true }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    static func parse(_ data: Data, now: Date = .now) throws -> Self {
        struct Response: Decodable {
            struct Item: Decodable {
                let reset_type: String
                let status: String
                let expires_at: String?
            }
            let available_count: Int
            let credits: [Item]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.available_count >= 0 else { throw ParseError.invalidCount }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        let credits = try response.credits.filter {
            $0.status == "available" && $0.reset_type == "codex_rate_limits"
        }.map { item -> Credit in
            guard let raw = item.expires_at else { return Credit(expiresAt: nil) }
            guard let date = fractional.date(from: raw) ?? standard.date(from: raw) else {
                throw ParseError.invalidExpiry
            }
            return Credit(expiresAt: date)
        }
        return Self(availableCount: response.available_count, credits: credits, updatedAt: now)
    }

    enum ParseError: Error { case invalidCount, invalidExpiry }
}
