import CryptoKit
import Foundation

enum DeepSeekKeyError: Error {
    case invalid
    case unreadable
    case duplicate
}

struct DeepSeekProvider: Provider {
    let tool: ToolKind = .deepSeek
    let treatsImportedCredentialsAsActiveSelection = false
    var client = QuotaHTTPClient(maxAttempts: 1)

    func importCurrentCredentials() async throws -> String {
        throw ProviderError.noUsableCredential(tool: tool)
    }

    func activate(account: Account, secret: String) async throws {}

    func accountIdentity(from secret: String) -> String? {
        let digest = SHA256.hash(data: Data(secret.utf8))
        return "deepseek-key-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    func prepareAccount(_ account: Account, secret: String) async throws -> Account {
        var account = account
        account.settings.identityKey = accountIdentity(from: secret)
        return account
    }

    func fetchQuota(secret: String) async throws -> QuotaSnapshot {
        guard !secret.isEmpty, !secret.contains(where: \.isWhitespace) else {
            throw DeepSeekKeyError.invalid
        }

        var request = URLRequest(
            url: URL(string: "https://api.deepseek.com/user/balance")!,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        do {
            data = try await client.data(for: request, operation: "DeepSeek balance")
        } catch let error as QuotaHTTPError where error.statusCode == 401 {
            throw DeepSeekKeyError.invalid
        }
        return try Self.snapshot(from: data)
    }

    static func snapshot(from data: Data) throws -> QuotaSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let amounts = try response.balanceInfos.map { info in
            AccountBalance.Amount(
                currency: info.currency,
                total: try parseAmount(info.totalBalance),
                granted: try parseAmount(info.grantedBalance),
                toppedUp: try parseAmount(info.toppedUpBalance)
            )
        }.sorted { $0.currency < $1.currency }
        guard Set(amounts.map(\.currency)).count == amounts.count else {
            throw ProviderError.network("Invalid DeepSeek balance response")
        }
        let balance = AccountBalance(isAvailable: response.isAvailable, amounts: amounts)
        return QuotaSnapshot(
            source: "DeepSeek API",
            primary: nil,
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            balance: balance,
            updatedAt: Date(),
            availabilityStatus: balance.isExhausted ? .quotaExhausted : .normal,
            note: nil
        )
    }

    private static func parseAmount(_ value: String) throws -> Decimal {
        guard value.wholeMatch(of: /-?[0-9]+(?:\.[0-9]+)?/) != nil,
              let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            throw ProviderError.network("Invalid DeepSeek balance response")
        }
        return amount
    }

    private struct Response: Decodable {
        struct BalanceInfo: Decodable {
            let currency: String
            let totalBalance: String
            let grantedBalance: String
            let toppedUpBalance: String

            enum CodingKeys: String, CodingKey {
                case currency
                case totalBalance = "total_balance"
                case grantedBalance = "granted_balance"
                case toppedUpBalance = "topped_up_balance"
            }
        }

        let isAvailable: Bool
        let balanceInfos: [BalanceInfo]

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }
}
