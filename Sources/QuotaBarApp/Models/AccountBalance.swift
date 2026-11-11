import Foundation

struct AccountBalance: Codable, Equatable, Sendable {
    struct Amount: Codable, Equatable, Identifiable, Sendable {
        let currency: String
        let total: Decimal
        let granted: Decimal
        let toppedUp: Decimal

        var id: String { currency }

        func formatted(_ value: Decimal, locale: Locale = .current) -> String {
            value.formatted(.currency(code: currency).locale(locale))
        }
    }

    let isAvailable: Bool
    let amounts: [Amount]

    var primary: Amount? { amounts.first }
    var isExhausted: Bool { !amounts.isEmpty && amounts.allSatisfy { $0.total <= 0 } }
}
