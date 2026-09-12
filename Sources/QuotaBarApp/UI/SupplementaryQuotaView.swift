import SwiftUI

struct SupplementaryQuotaView: View {
    let quota: QuotaSnapshot
    let tool: ToolKind
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss
    private var text: AppText { AppText(language: language) }
    private var windows: [QuotaDisplayMetric] {
        quota.supplementaryMetrics(for: tool).filter {
            if case .credits = $0 { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text.otherQuotaTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Branding.inkStrong)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Branding.inkSubtle)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: Branding.radiusSmallControl).fill(Branding.controlSurface))
                }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(text.string(.cancel))
            }
            if windows.count + quota.spending.count <= 3 {
                detailRows
            } else {
                ScrollView { detailRows }
                    .frame(height: 300)
            }
            Text(text.quotaSnapshotMeta(quota)).font(.caption2).foregroundStyle(.secondary)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Branding.inkStrong)
        .padding(14)
        .frame(width: 320)
        .background(Branding.pageBackground)
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(windows, id: \.title) { metric in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(text.quotaLabel(metric.title))
                            .lineLimit(1)
                            .help(text.quotaLabel(metric.title))
                        Spacer()
                        if let ratio = metric.ratio {
                            Text("\(Int((ratio * 100).rounded()))% \(text.string(.remaining))")
                                .monospacedDigit()
                                .foregroundStyle(quotaTint(ratio))
                        }
                    }
                    if let ratio = metric.ratio {
                        RatioBar(value: ratio, tint: ratio <= 0.20 ? quotaTint(ratio) : Branding.quotaFill)
                    }
                    QuotaResetDetail(resetAt: metric.resetAt, language: language)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Branding.radiusSmallControl).fill(Branding.controlSurface))
            }
            ForEach(Array(quota.spending.enumerated()), id: \.offset) { _, spend in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(text.spendLabel(spend.label))
                        Spacer()
                        Text(spend.used, format: .currency(code: spend.currency))
                            .monospacedDigit()
                    }
                    if let limit = spend.limit {
                        Text(text.spendLimit(limit, currency: spend.currency))
                            .foregroundStyle(Branding.inkMuted)
                    } else {
                        Text(text.spendLimitUnknown).foregroundStyle(Branding.inkMuted)
                    }
                    if let resetAt = spend.resetAt {
                        QuotaResetDetail(resetAt: resetAt, language: language)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Branding.radiusSmallControl).fill(Branding.controlSurface))
            }
            // A credit balance is useful even when the service supplies no total.
            if let balance = quota.creditsRemaining {
                HStack {
                    Text(text.quotaLabel("Credits"))
                    Spacer()
                    if let total = quota.creditsTotal, total > 0 {
                        Text("\(balance.formatted(.number.precision(.fractionLength(0...2)))) / \(total.formatted(.number.precision(.fractionLength(0...2))))")
                    } else {
                        Text(balance, format: .number.precision(.fractionLength(0...2)))
                    }
                }
            }
        }
    }

    private func quotaTint(_ ratio: Double) -> Color {
        if ratio <= 0.001 { return Branding.danger }
        if ratio <= 0.20 { return Branding.warning }
        return Branding.inkStrong
    }

}
