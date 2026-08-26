import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Account card status presenter")
struct AccountCardStatusPresenterTests {
    private func snapshot(
        primary: QuotaWindow?,
        secondary: QuotaWindow? = nil,
        creditsRemaining: Double? = nil,
        creditsTotal: Double? = nil,
        updatedAt: Date = Date(),
        availabilityStatus: QuotaAvailabilityStatus? = nil,
        note: String? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            source: "Fixture",
            primary: primary,
            secondary: secondary,
            creditsRemaining: creditsRemaining,
            creditsTotal: creditsTotal,
            updatedAt: updatedAt,
            availabilityStatus: availabilityStatus,
            note: note
        )
    }

    private func status(
        tool: ToolKind = .cursor,
        quota: QuotaSnapshot?,
        loadState: AccountLoadState = .loaded,
        isRefreshing: Bool = false,
        errorMessage: String? = nil,
        errorRequiresUserAction: Bool = false
    ) -> AccountVisualStatus {
        AccountCardStatusPresenter.status(
            tool: tool,
            quota: quota,
            loadState: loadState,
            isRefreshing: isRefreshing,
            errorMessage: errorMessage,
            errorRequiresUserAction: errorRequiresUserAction
        )
    }

    @Test("error without quota needs action or stays pending")
    func errorWithoutQuota() {
        #expect(status(quota: nil, errorMessage: "boom", errorRequiresUserAction: true) == .error)
        #expect(status(quota: nil, errorMessage: "boom", errorRequiresUserAction: false) == .pending)
    }

    @Test("refresh states win over loaded quota")
    func refreshingStates() {
        let quota = snapshot(primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil))
        #expect(status(quota: quota, isRefreshing: true) == .refreshing)
        #expect(status(quota: quota, loadState: .loadingInitial) == .refreshing)
        #expect(status(quota: nil, loadState: .idle) == .pending)
    }

    @Test("stale snapshot reports stale")
    func staleSnapshot() {
        let quota = snapshot(
            primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil),
            updatedAt: Date().addingTimeInterval(-3600)
        )
        #expect(status(quota: quota) == .stale)
    }

    @Test("remaining ratio maps to healthy, warning, exhausted")
    func remainingRatioThresholds() {
        let healthy = snapshot(primary: QuotaWindow(label: "5h", used: 30, limit: 100, resetAt: nil))
        #expect(status(quota: healthy) == .healthy)

        let warning = snapshot(primary: QuotaWindow(label: "5h", used: 85, limit: 100, resetAt: nil))
        #expect(status(quota: warning) == .warning)

        let exhausted = snapshot(primary: QuotaWindow(label: "5h", used: 100, limit: 100, resetAt: nil))
        #expect(status(quota: exhausted) == .exhausted)
    }

    @Test("worst window drives the status")
    func worstWindowWins() {
        let quota = snapshot(
            primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil),
            secondary: QuotaWindow(label: "Weekly", used: 100, limit: 100, resetAt: nil)
        )
        #expect(status(quota: quota) == .exhausted)
    }

    @Test("availability status overrides window ratios")
    func availabilityOverrides() {
        let limited = snapshot(
            primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil),
            availabilityStatus: .sessionRateLimited
        )
        #expect(status(quota: limited) == .warning)

        let blocked = snapshot(
            primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil),
            availabilityStatus: .quotaExhausted
        )
        #expect(status(quota: blocked) == .exhausted)
    }

    @Test("empty metrics mean noQuota except for Claude Code")
    func emptyMetrics() {
        let empty = snapshot(primary: nil)
        #expect(status(tool: .cursor, quota: empty) == .noQuota)
        #expect(status(tool: .claudeCode, quota: empty) == .healthy)
    }

    @Test("Claude Code limiting metrics ignore informational windows")
    func claudeLimitingMetrics() {
        // A low (but not exhausted) tertiary window is informational for Claude
        // Code: it must not drag the card into the warning state.
        let quota = QuotaSnapshot(
            source: "Claude Code",
            primary: nil,
            secondary: nil,
            tertiary: QuotaWindow(label: "Opus", used: 85, limit: 100, resetAt: nil),
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(),
            note: nil
        )
        #expect(AccountCardStatusPresenter.quotaLimitingMetrics(tool: .claudeCode, quota: quota).isEmpty)
        #expect(status(tool: .claudeCode, quota: quota) == .healthy)
        #expect(status(tool: .cursor, quota: quota) == .warning)
    }

    @Test("a card-worthy note is left to the footer instead of being printed twice")
    func metricFallbackDetailSkipsFooterNotes() {
        let text = AppText(language: .simplifiedChinese)
        for note in [
            QuotaNoteCatalog.claudeApiKeyNoWindows,
            QuotaNoteCatalog.codexEmptyQuotaFields,
            QuotaNoteCatalog.cursorLegacyNoStandardFields
        ] {
            #expect(text.shouldDisplayNoteOnCard(note))
            let quota = snapshot(primary: nil, note: note)
            #expect(AccountCardStatusPresenter.metricFallbackDetail(quota: quota, hasVisibleMetrics: false, text: text) == nil)
        }
    }

    @Test("a freshness note the footer hides still labels the empty metric strip")
    func metricFallbackDetailKeepsFreshnessNotes() {
        let text = AppText(language: .simplifiedChinese)
        let note = QuotaNoteCatalog.codexLiveUnavailableCache
        #expect(!text.shouldDisplayNoteOnCard(note))
        let quota = snapshot(primary: nil, note: note)
        #expect(AccountCardStatusPresenter.metricFallbackDetail(quota: quota, hasVisibleMetrics: false, text: text) == text.localizedNote(note))
    }

    @Test("a strip that has metrics to plot needs no fallback detail")
    func metricFallbackDetailUnusedWhenMetricsExist() {
        let text = AppText(language: .simplifiedChinese)
        let quota = snapshot(primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil), note: QuotaNoteCatalog.codexLiveUnavailableCache)
        #expect(AccountCardStatusPresenter.metricFallbackDetail(quota: quota, hasVisibleMetrics: true, text: text) == nil)
        #expect(AccountCardStatusPresenter.metricFallbackDetail(quota: nil, hasVisibleMetrics: false, text: text) == nil)
    }
}

@Suite("Quota notification evaluator")
struct QuotaNotificationEvaluatorTests {
    @Test("threshold crossing fires once on transition")
    func thresholdCrossing() {
        #expect(QuotaNotificationEvaluator.event(previousRatio: 0.35, currentRatio: 0.15, threshold: 0.20) == .quotaLow(remainingPercent: 15))
        #expect(QuotaNotificationEvaluator.event(previousRatio: 0.15, currentRatio: 0.12, threshold: 0.20) == nil)
        #expect(QuotaNotificationEvaluator.event(previousRatio: nil, currentRatio: 0.15, threshold: 0.20) == nil)
    }

    @Test("exhaustion fires only on transition with a previous reading")
    func exhaustionTransition() {
        #expect(QuotaNotificationEvaluator.event(previousRatio: 0.05, currentRatio: 0.0, threshold: 0.20) == .quotaExhausted)
        #expect(QuotaNotificationEvaluator.event(previousRatio: 0.0, currentRatio: 0.0, threshold: 0.20) == nil)
        #expect(QuotaNotificationEvaluator.event(previousRatio: nil, currentRatio: 0.0, threshold: 0.20) == nil)
    }

    @Test("recovery fires when quota returns after exhaustion")
    func recoveryTransition() {
        #expect(QuotaNotificationEvaluator.event(previousRatio: 0.0, currentRatio: 0.9, threshold: 0.20) == .quotaRecovered(remainingPercent: 90))
        #expect(QuotaNotificationEvaluator.event(previousRatio: 0.0, currentRatio: 0.05, threshold: 0.20) == nil)
        #expect(QuotaNotificationEvaluator.event(previousRatio: 0.5, currentRatio: 0.9, threshold: 0.20) == nil)
    }

    @Test("missing current reading never fires")
    func missingCurrentReading() {
        #expect(QuotaNotificationEvaluator.event(previousRatio: 0.5, currentRatio: nil, threshold: 0.20) == nil)
    }
}
