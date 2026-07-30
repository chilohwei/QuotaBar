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
        #expect(entry.lines.map(\.level) == [.normal, .exhausted])
    }

    @Test("warning levels match the dashboard thresholds")
    func warningLevelsMatchDashboardThresholds() throws {
        let entries = StatusBarQuotaPresenter.entries(for: [
            StatusBarQuotaInput(
                tool: .cursor,
                accountName: "Low",
                quota: QuotaSnapshot(
                    source: "Fixture",
                    primary: QuotaWindow(label: "Monthly", used: 85, limit: 100, resetAt: nil),
                    secondary: QuotaWindow(label: "Weekly", used: 30, limit: 100, resetAt: nil),
                    creditsRemaining: nil,
                    creditsTotal: nil,
                    updatedAt: Date(timeIntervalSince1970: 1),
                    note: nil
                )
            )
        ])

        let entry = try #require(entries.first)
        #expect(entry.lines.map(\.level) == [.low, .normal])
    }

    @Test("tooltip falls back when there are no visible entries")
    func tooltipFallback() {
        let text = AppText(language: .english)

        #expect(StatusBarQuotaPresenter.tooltip(for: [], text: text) == text.string(.statusBarNoData))
    }

    @Test("tooltip includes snapshot source freshness and availability")
    func tooltipIncludesSnapshotMetadata() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_782_000_000)
        let entries = StatusBarQuotaPresenter.entries(for: [
            StatusBarQuotaInput(
                tool: .claudeCode,
                accountName: "Claude",
                quota: QuotaSnapshot(
                    source: "Claude Code OAuth Cache",
                    primary: QuotaWindow(label: "5h", used: 71, limit: 100, resetAt: nil),
                    secondary: nil,
                    creditsRemaining: nil,
                    creditsTotal: nil,
                    updatedAt: updatedAt,
                    availabilityStatus: .sessionRateLimited,
                    note: nil
                )
            )
        ])

        let tooltip = StatusBarQuotaPresenter.tooltip(for: entries, text: AppText(language: .english))

        #expect(tooltip.contains("remaining 29%"))
        #expect(tooltip.contains("Current session is rate-limited"))
        #expect(tooltip.contains("Claude Code Cache"))
        #expect(tooltip.contains("updated"))
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

    @Test("visible tool stays in the menu bar while quota is unavailable")
    func unavailableQuotaKeepsVisibleEntry() throws {
        let entries = StatusBarQuotaPresenter.entries(for: [
            StatusBarQuotaInput(
                tool: .claudeCode,
                accountName: "Claude",
                quota: nil
            )
        ])

        let entry = try #require(entries.first)
        #expect(entry.lines.map(\.text) == ["--"])
        #expect(entry.remainingPercent == nil)
        let tooltip = StatusBarQuotaPresenter.tooltip(
            for: entries,
            text: AppText(language: .simplifiedChinese)
        )
        #expect(tooltip.contains("暂无数据"))
        #expect(!tooltip.contains("0%"))
    }

    @Test("tertiary quota is used when primary windows are absent")
    func tertiaryQuotaFallback() throws {
        let entries = StatusBarQuotaPresenter.entries(for: [
            StatusBarQuotaInput(
                tool: .claudeCode,
                accountName: "Claude",
                quota: QuotaSnapshot(
                    source: "Claude Code StatusLine",
                    primary: nil,
                    secondary: nil,
                    tertiary: QuotaWindow(label: "Sonnet", used: 25, limit: 100, resetAt: nil),
                    creditsRemaining: nil,
                    creditsTotal: nil,
                    updatedAt: Date(timeIntervalSince1970: 1),
                    note: nil
                )
            )
        ])

        #expect(try #require(entries.first).lines.map(\.text) == ["75%"])
    }
}
