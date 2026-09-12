import Foundation

struct RefreshBackoffPolicy: Sendable {
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    init(baseDelay: TimeInterval = 60, maxDelay: TimeInterval = 15 * 60) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    func delay(afterFailureCount failureCount: Int) -> TimeInterval {
        let exponent = max(min(failureCount - 1, 4), 0)
        return min(baseDelay * pow(2, Double(exponent)), maxDelay)
    }
}
