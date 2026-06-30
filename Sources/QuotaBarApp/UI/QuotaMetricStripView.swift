import SwiftUI

struct LoadingQuotaPlaceholder: View {
    let language: AppLanguage

    private var text: AppText { AppText(language: language) }

    var body: some View {
        CompactQuotaMetricStrip(
            tiles: [
                ("5h", nil),
                ("Weekly", nil)
            ],
            fallbackResetAt: nil,
            language: language,
            fallbackDetail: text.string(.refreshing)
        )
    }
}

struct CompactQuotaMetricStrip: View {
    let tiles: [(title: String, metric: QuotaDisplayMetric?)]
    let fallbackResetAt: Date?
    let language: AppLanguage
    var fallbackDetail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                CompactQuotaMetricTile(
                    title: tile.title,
                    metric: tile.metric,
                    fallbackResetAt: fallbackResetAt,
                    language: language,
                    fallbackDetail: fallbackDetail
                )
            }
        }
    }
}

private struct CompactQuotaMetricTile: View {
    let title: String
    let metric: QuotaDisplayMetric?
    let fallbackResetAt: Date?
    let language: AppLanguage
    let fallbackDetail: String?

    private var text: AppText { AppText(language: language) }

    private var state: (ratio: Double, resetAt: Date?, isKnown: Bool) {
        guard let metric,
              let ratio = metric.ratio else {
            return (0, nil, false)
        }
        return (ratio, metric.resetAt, true)
    }

    private var tint: Color {
        guard state.isKnown else { return Branding.inkSubtle }
        if state.ratio <= 0.001 { return Branding.danger }
        if state.ratio <= 0.20 { return Branding.warning }
        return Branding.success
    }

    private var percentTextColor: Color {
        guard state.isKnown else { return Branding.inkSubtle }
        return tint
    }

    var body: some View {
        let resolved = state

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.quotaLabel(title))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Branding.inkMuted)
                        .lineLimit(1)

                    Text(text.string(.remaining))
                        .font(.system(size: 10, weight: .light))
                        .foregroundStyle(Branding.inkSubtle)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(resolved.isKnown ? "\(Int((resolved.ratio * 100).rounded()))%" : "--")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(percentTextColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            RatioBar(value: resolved.isKnown ? resolved.ratio : 0, tint: tint)

            Text(detailText(resolved: resolved))
                .font(.system(size: 10, weight: .light))
                .foregroundStyle(Branding.inkSubtle.opacity(0.78))
                .lineLimit(1)
                .frame(minHeight: 13, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
    }

    private func detailText(resolved: (ratio: Double, resetAt: Date?, isKnown: Bool)) -> String {
        if resolved.isKnown, let resetAt = resolved.resetAt ?? fallbackResetAt {
            return text.resetAt(resetAt)
        }
        if let fallbackDetail {
            return fallbackDetail
        }
        return text.string(.waitingData)
    }
}

private struct RatioBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Branding.track)
                    .overlay(
                        Capsule()
                            .stroke(Branding.iconHighlight, lineWidth: 0.5)
                    )
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * value, value > 0 ? 7 : 0))

                // Warning threshold marker at 20%, where the bar turns amber.
                Rectangle()
                    .fill(Branding.pageBackground.opacity(0.85))
                    .frame(width: 1, height: 6)
                    .offset(x: proxy.size.width * RatioBar.warningThreshold)
            }
        }
        .frame(height: 6)
    }

    static let warningThreshold: Double = 0.20
}
