import Foundation

struct StatusBarQuotaInput {
    let tool: ToolKind
    let accountName: String
    let quota: QuotaSnapshot?
    var alternativeAccountName: String?
}

struct StatusBarQuotaPresenter {
    static func entries(for inputs: [StatusBarQuotaInput]) -> [StatusBarQuotaEntry] {
        inputs.map { input in
            // Two stacked lines next to the logo: top = primary window (e.g. 5h),
            // bottom = secondary window (e.g. weekly). Plans that are known to meter both
            // always keep both slots; everything else collapses to whatever real metric
            // exists, and falls back to an honest placeholder so the tool stays visible
            // while it waits for its first payload.
            let displayLines: [StatusBarQuotaLine]
            if metersBothSubscriptionWindows(input) {
                displayLines = [
                    quotaLine(for: input.quota?.primaryPanelMetric) ?? placeholderLine,
                    quotaLine(for: input.quota?.secondaryPanelMetric) ?? placeholderLine
                ]
            } else {
                var lines = [
                    input.quota?.primaryPanelMetric,
                    input.quota?.secondaryPanelMetric
                ].compactMap(quotaLine(for:))
                if lines.isEmpty,
                   let tertiaryLine = quotaLine(for: input.quota?.tertiaryPanelMetric) {
                    lines = [tertiaryLine]
                }
                displayLines = lines.isEmpty ? [placeholderLine] : lines
            }

            let remainingPercent = input.quota?.statusBarMetric?.ratio.map {
                Int((min(max($0, 0), 1) * 100).rounded())
            }
            return StatusBarQuotaEntry(
                tool: input.tool,
                accountName: input.accountName,
                remainingPercent: remainingPercent,
                source: input.quota?.source,
                updatedAt: input.quota?.updatedAt,
                availabilityStatus: input.quota?.effectiveAvailabilityStatus,
                lines: displayLines,
                alternativeAccountName: input.alternativeAccountName
            )
        }
    }

    static func tooltip(for entries: [StatusBarQuotaEntry], text: AppText) -> String {
        guard !entries.isEmpty else {
            return text.string(.statusBarNoData)
        }
        return entries
            .map { entry in
                let metadata: String?
                if let source = entry.source, let updatedAt = entry.updatedAt {
                    metadata = text.quotaSnapshotMeta(source: source, updatedAt: updatedAt)
                } else {
                    metadata = nil
                }
                var line: String
                if let remainingPercent = entry.remainingPercent {
                    line = text.statusBarTooltip(
                        tool: entry.tool,
                        remainingPercent: remainingPercent,
                        accountName: entry.accountName,
                        metadata: metadata,
                        availability: entry.availabilityStatus
                    )
                } else {
                    var parts = [
                        "\(entry.tool.displayName) \(entry.accountName)",
                        text.string(.waitingData)
                    ]
                    if let availability = entry.availabilityStatus.flatMap(text.quotaAvailabilityText) {
                        parts.append(availability)
                    }
                    if let metadata {
                        parts.append(metadata)
                    }
                    line = parts.joined(separator: " · ")
                }
                if let alternative = entry.alternativeAccountName {
                    line += "\n· " + text.alternativeAccountAvailable(alternative)
                }
                return line
            }
            .joined(separator: "\n")
    }

    // Same thresholds as the dashboard cards: ≤20% is a warning, 0% is exhausted.
    static let lowRemainingThresholdPercent = 20

    private static let placeholderLine = StatusBarQuotaLine(text: "--", level: .normal)

    /// A paid Claude Code subscription is always metered on both a 5-hour and a weekly window, even
    /// when a payload has only reported one of them yet (a fresh session, an OAuth cache captured
    /// before the first weekly reading, a window pruned for having expired). Reserve both lines for
    /// those accounts: one lone percentage is ambiguous — the user cannot tell which window it is —
    /// and the menu-bar item would jump in width once the missing window finally lands. Free plans,
    /// API keys and third-party providers have no such pair and keep the compact form.
    private static func metersBothSubscriptionWindows(_ input: StatusBarQuotaInput) -> Bool {
        input.tool == .claudeCode
            && ClaudeCodeProvider.isPaidSubscriptionPlanName(input.quota?.planName)
    }

    private static func quotaLine(for metric: QuotaDisplayMetric?) -> StatusBarQuotaLine? {
        guard let ratio = metric?.ratio else { return nil }
        let percent = Int((min(max(ratio, 0), 1) * 100).rounded())
        let level: StatusBarQuotaWarningLevel
        if percent <= 0 {
            level = .exhausted
        } else if percent <= lowRemainingThresholdPercent {
            level = .low
        } else {
            level = .normal
        }
        return StatusBarQuotaLine(text: "\(percent)%", level: level)
    }
}
