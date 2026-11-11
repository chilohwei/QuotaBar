import Foundation
import Testing
@testable import QuotaBarApp

struct DeepSeekBalanceTests {
    @Test func unavailableBalanceSurvivesCachingAndDisplaysAsMoney() throws {
        let data = Data("""
            {
              "is_available": false,
              "balance_infos": [
                {"currency":"USD","total_balance":"0.00","granted_balance":"0","topped_up_balance":"0"},
                {"currency":"CNY","total_balance":"110.05","granted_balance":"10.02","topped_up_balance":"100.03"}
              ]
            }
            """.utf8)
        let snapshot = try DeepSeekProvider.snapshot(from: data)
        let cached = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
            .replacing(source: "DeepSeek API Cache")
        let balance = try #require(cached.balance)
        let primary = try #require(balance.primary)
        #expect(primary.currency == "CNY")
        #expect(primary.total == Decimal(string: "110.05"))
        #expect(primary.granted + primary.toppedUp == primary.total)
        #expect(balance.amounts.map(\.currency) == ["CNY", "USD"])
        #expect(!balance.isAvailable)
        #expect(cached.effectiveAvailabilityStatus == .normal)

        let text = AppText(language: .english)
        let entries = StatusBarQuotaPresenter.entries(for: [
            StatusBarQuotaInput(
                tool: .deepSeek, accountName: "Work", quota: cached,
                isStale: true, refreshError: text.deepSeekUnreadableKey
            )
        ])
        let entry = try #require(entries.first)
        #expect(entry.remainingPercent == nil)
        #expect(entry.lines.first?.text == primary.formatted(primary.total))
        #expect(entry.lines.first?.level == .low)
        #expect(entry.resetWindows.isEmpty)
        #expect(entry.isStale)
        let tooltip = StatusBarQuotaPresenter.tooltip(for: entries, text: text)
        #expect(tooltip.contains(text.balanceUnavailable))
        #expect(tooltip.contains(text.deepSeekUnreadableKey))
    }

    @Test func zeroBalanceIsExhaustedAndMalformedAmountsFail() throws {
        func response(total: String) -> Data {
            Data("""
                {"is_available":false,"balance_infos":[
                  {"currency":"USD","total_balance":"\(total)","granted_balance":"0","topped_up_balance":"0"}
                ]}
                """.utf8)
        }

        let zero = try DeepSeekProvider.snapshot(from: response(total: "0.00"))
        #expect(zero.effectiveAvailabilityStatus == .quotaExhausted)
        #expect(throws: (any Error).self) {
            try DeepSeekProvider.snapshot(from: response(total: "0.00oops"))
        }
    }
}
