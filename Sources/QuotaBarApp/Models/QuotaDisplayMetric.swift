import Foundation

enum QuotaDisplayMetric: Equatable, Sendable {
    case window(QuotaWindow)
    case credits(remaining: Double, total: Double, periodEnd: Date?)

    var title: String {
        switch self {
        case .window(let window):
            return window.label
        case .credits:
            return "Credits"
        }
    }

    var ratio: Double? {
        switch self {
        case .window(let window):
            guard window.limit > 0 else { return nil }
            return min(max(window.remaining / window.limit, 0), 1)
        case .credits(let remaining, let total, _):
            guard total > 0 else { return nil }
            return min(max(remaining / total, 0), 1)
        }
    }

    var resetAt: Date? {
        switch self {
        case .window(let window):
            return window.resetAt
        case .credits(_, _, let periodEnd):
            return periodEnd
        }
    }

    var window: QuotaWindow {
        switch self {
        case .window(let window):
            return window
        case .credits(let remaining, let total, let periodEnd):
            return QuotaWindow(
                label: "Credits",
                used: max(total - remaining, 0),
                limit: total,
                resetAt: periodEnd
            )
        }
    }
}
