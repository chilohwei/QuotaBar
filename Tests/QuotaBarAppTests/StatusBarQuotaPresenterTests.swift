import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Status bar quota presenter")
struct StatusBarQuotaPresenterTests {
    @Test("entries use primary and secondary quota percentages")
    func entriesUseQuotaPercentages() throws {
        let entries = StatusBarQuotaPresenter.entries(for: [
            StatusBarQuotaInput(
                tool: .codex,
                accountName: "Work",
                quota: QuotaSnapshot(
                    source: "Fixture",
                    primary: QuotaWindow(label: "5h", used: 20, limit: 100, resetAt: nil),
                    secondary: QuotaWindow(label: "Weekly", used: 100, limit: 100, resetAt: nil),
                    creditsRemaining: nil,
                    creditsTotal: nil,
                    updatedAt: Date(timeIntervalSince1970: 1),
                    note: nil
                )
            )
        ])

        let entry = try #require(entries.first)
        #expect(entry.tool == .codex)
        #expect(entry.accountName == "Work")
        #expect(entry.remainingPercent == 0)
        #expect(entry.lines.map(\.text) == ["80%", "0%"])
        #expect(entry.lines.map(\.isZero) == [false, true])
    }

    @Test("tooltip falls back when there are no visible entries")
    func tooltipFallback() {
        let text = AppText(language: .english)

        #expect(StatusBarQuotaPresenter.tooltip(for: [], text: text) == text.string(.statusBarNoData))
    }

    @Test("remaining percentage is clamped for status bar tooltip")
    func remainingPercentageIsClamped() throws {
        let entries = StatusBarQuotaPresenter.entries(for: [
            StatusBarQuotaInput(
                tool: .cursor,
                accountName: "Team",
                quota: QuotaSnapshot(
                    source: "Fixture",
                    primary: QuotaWindow(label: "Monthly", used: -25, limit: 100, resetAt: nil),
                    secondary: nil,
                    creditsRemaining: nil,
                    creditsTotal: nil,
                    updatedAt: Date(timeIntervalSince1970: 1),
                    note: nil
                )
            )
        ])

        #expect(try #require(entries.first).remainingPercent == 100)
    }
}
