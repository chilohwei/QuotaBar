import Foundation

extension CursorProvider {
    func parseSpendDetail(_ bucket: [String: Any]?, label: String, resetAt: Date?) -> QuotaSpend? {
        guard let bucket, firstBool(in: bucket, keys: ["enabled"]) != false else { return nil }
        func value(_ preferred: [String], aliases: Set<String>) -> Double? {
            for key in preferred { if let number = directDouble(in: bucket, keys: [key]) { return number } }
            return directDouble(in: bucket, keys: aliases)
        }
        let limit = value(["individualLimit", "individual_limit", "pooledLimit", "pooled_limit"], aliases: Self.limitAmountKeys)
        let reported = value(["individualUsed", "individual_used", "pooledUsed", "pooled_used", "includedSpend", "included_spend"], aliases: Self.usedAmountKeys)
        let remaining = value(["individualRemaining", "individual_remaining", "pooledRemaining", "pooled_remaining"], aliases: Self.remainingAmountKeys)
        let inferred = limit.flatMap { cap in remaining.map { max(cap - $0, 0) } }
        guard let used = reported ?? inferred, used.isFinite, used >= 0 else { return nil }
        return QuotaSpend(label: label, used: used / 100,
                          limit: limit.flatMap { $0.isFinite && $0 > 0 ? $0 / 100 : nil },
                          currency: "USD", resetAt: resetAt)
    }
}
