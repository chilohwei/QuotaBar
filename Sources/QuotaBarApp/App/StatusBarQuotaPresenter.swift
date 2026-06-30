import Foundation

struct StatusBarQuotaInput {
    let tool: ToolKind
    let accountName: String
    let quota: QuotaSnapshot
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
                lines: lines
            )
        }
    }

    static func tooltip(for entries: [StatusBarQuotaEntry], text: AppText) -> String {
        guard !entries.isEmpty else {
            return text.string(.statusBarNoData)
        }
        return entries
            .map { entry in
                text.statusBarTooltip(
                    tool: entry.tool,
                    remainingPercent: entry.remainingPercent,
                    accountName: entry.accountName
                )
            }
            .joined(separator: "\n")
    }

    private static func quotaLine(for metric: QuotaDisplayMetric?) -> StatusBarQuotaLine? {
        guard let ratio = metric?.ratio else { return nil }
        let percent = Int((min(max(ratio, 0), 1) * 100).rounded())
        return StatusBarQuotaLine(text: "\(percent)%", isZero: percent <= 0)
    }
}
