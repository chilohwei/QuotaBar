import Foundation

enum QuotaFreshness {
    static let staleWarningAge: TimeInterval = 10 * 60
    private static let expiredResetGrace: TimeInterval = 60

    static func isStale(
        _ snapshot: QuotaSnapshot,
        now: Date = Date(),
        staleAfter: TimeInterval = staleWarningAge
    ) -> Bool {
        if now.timeIntervalSince(snapshot.updatedAt) > staleAfter {
            return true
        }
        if hasExpiredQuotaWindows(snapshot, now: now) {
            return true
        }
        return false
    }

    static func hasExpiredQuotaWindows(_ snapshot: QuotaSnapshot, now: Date = Date()) -> Bool {
        snapshot.orderedMetrics.contains { metric in
            guard let resetAt = metric.resetAt else { return false }
            return resetAt.addingTimeInterval(expiredResetGrace) < now
        }
    }
}
