import Foundation

struct QuotaWindow: Codable, Equatable, Sendable {
    let label: String
    let used: Double
    let limit: Double
    let resetAt: Date?

    var remaining: Double {
        max(limit - used, 0)
    }

    var usagePercent: Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    var remainingPercent: Double {
        max(0, 1 - usagePercent) * 100
    }
    static func isAccountLimit(_ window: QuotaWindow) -> Bool {
        window.limit > 0 && !window.label.contains("·") && window.label != "On-demand"
    }

}
