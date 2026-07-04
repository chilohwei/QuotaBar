import Foundation

struct StatusBarQuotaInput {
    let tool: ToolKind
    let accountName: String
    let quota: QuotaSnapshot
    var alternativeAccountName: String?
}

struct StatusBarQuotaPresenter {
    static func entries(for inputs: [StatusBarQuotaInput]) -> [StatusBarQuotaEntry] {
        inputs.compactMap { input in
            // Two stacked lines next to the logo: top = primary window (e.g. 5h),
            // bottom = secondary window (e.g. weekly). Read live from the snapshot.
            let lines = [input.quota.primaryPanelMetric, input.quota.secondaryPanelMetric]
                .compactMap(quotaLine(for:))
            guard !lines.isEmpty else { return nil }

            let remainingRatio = min(max(input.quota.statusBarMetric?.ratio ?? 0, 0), 1)
            return StatusBarQuotaEntry(
                tool: input.tool,
                accountName: input.accountName,
                remainingPercent: Int(max(remainingRatio * 100, 0).rounded()),
                source: input.quota.source,
                updatedAt: input.quota.updatedAt,
                availabilityStatus: input.quota.effectiveAvailabilityStatus,
                lines: lines,
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
                var line = text.statusBarTooltip(
                    tool: entry.tool,
                    remainingPercent: entry.remainingPercent,
                    accountName: entry.accountName,
                    metadata: text.quotaSnapshotMeta(source: entry.source, updatedAt: entry.updatedAt),
                    availability: entry.availabilityStatus
                )
                if let alternative = entry.alternativeAccountName {
                    line += "\n· " + text.alternativeAccountAvailable(alternative)
                }
                return line
            }
            .joined(separator: "\n")
    }

    // Same thresholds as the dashboard cards: ≤20% is a warning, 0% is exhausted.
    static let lowRemainingThresholdPercent = 20

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
