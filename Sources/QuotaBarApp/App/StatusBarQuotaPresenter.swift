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
            let lines = input.quota?.mainMetrics(for: input.tool).prefix(2).compactMap(quotaLine(for:)) ?? []
            let displayLines = lines.isEmpty ? [placeholderLine] : lines

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
                alternativeAccountName: input.alternativeAccountName,
                isStale: input.quota.map { QuotaFreshness.isStale($0) || $0.effectiveAvailabilityStatus == .serviceUnavailable } ?? false,
                resetWindows: input.quota?.mainMetrics(for: input.tool).map(\.window) ?? []
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
                for window in entry.resetWindows {
                    let reset = window.resetAt.map { text.resetCountdown($0, now: Date()) + " · " + text.exactReset($0) } ?? text.resetUnavailable
                    line += "\n\(text.quotaLabel(window.label)): \(reset)"
                }
                if entry.isStale { line += "\n" + text.string(.staleData) }
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
