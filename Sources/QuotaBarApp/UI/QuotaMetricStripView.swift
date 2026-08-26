import SwiftUI

struct LoadingQuotaPlaceholder: View {
    let language: AppLanguage
    var useRingLayout = false

    private var text: AppText { AppText(language: language) }

    var body: some View {
        if useRingLayout {
            RingQuotaMetricStrip(
                tiles: [
                    ("Total", nil),
                    ("Auto", nil),
                    ("API", nil)
                ],
                fallbackResetAt: nil,
                language: language,
                fallbackDetail: text.string(.refreshing)
            )
        } else {
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
}

struct CompactQuotaMetricStrip: View {
    let tiles: [(title: String, metric: QuotaDisplayMetric?)]
    let fallbackResetAt: Date?
    let language: AppLanguage
    var fallbackDetail: String?

    /// Three tiles across a 440pt panel leave each one too narrow for the
    /// side-by-side label/percentage row, so they switch to a stacked layout
    /// that gives the label the full tile width.
    private var isDense: Bool { tiles.count >= 3 }

    var body: some View {
        HStack(alignment: .top, spacing: isDense ? 9 : 12) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                CompactQuotaMetricTile(
                    title: tile.title,
                    metric: tile.metric,
                    fallbackResetAt: fallbackResetAt,
                    language: language,
                    fallbackDetail: fallbackDetail,
                    isDense: isDense
                )
            }
        }
    }
}

struct RingQuotaMetricStrip: View {
    let tiles: [(title: String, metric: QuotaDisplayMetric?)]
    let fallbackResetAt: Date?
    let language: AppLanguage
    var fallbackDetail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                RingQuotaMetricTile(
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

private struct RingQuotaMetricTile: View {
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
        return Branding.quotaFill
    }

    // A used-up window draws no arc at all, which on its own is indistinguishable
    // from "no data". The track and the number carry the alarm instead.
    private var isExhausted: Bool {
        state.isKnown && state.ratio <= 0.001
    }

    var body: some View {
        let resolved = state

        VStack(alignment: .center, spacing: 3) {
            Text(text.quotaLabel(title))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Branding.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .center)

            ZStack {
                MetricRing(
                    value: resolved.isKnown ? resolved.ratio : 0,
                    tint: tint,
                    track: isExhausted ? Branding.dangerSoft : Branding.track
                )
                .frame(width: 38, height: 38)

                Text(resolved.isKnown ? "\(Int((resolved.ratio * 100).rounded()))%" : "--")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isExhausted ? Branding.danger : (resolved.isKnown ? Branding.inkStrong : Branding.inkSubtle))
                    .monospacedDigit()
            }

            Text(detailText(resolved: resolved))
                .font(.system(size: 9.8, weight: .light))
                .foregroundStyle(Branding.inkSubtle.opacity(0.90))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(minHeight: 13)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .top)
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

private struct CompactQuotaMetricTile: View {
    let title: String
    let metric: QuotaDisplayMetric?
    let fallbackResetAt: Date?
    let language: AppLanguage
    let fallbackDetail: String?
    var isDense = false

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
        return Branding.quotaFill
    }

    // A used-up window draws a zero-width bar, which on its own is
    // indistinguishable from "no data". The track and the number carry the alarm.
    private var isExhausted: Bool {
        state.isKnown && state.ratio <= 0.001
    }

    private var percentTextColor: Color {
        guard state.isKnown else { return Branding.inkSubtle }
        return isExhausted ? Branding.danger : Branding.inkStrong
    }

    private var localizedTitle: String { text.quotaLabel(title) }

    private func percentText(resolved: (ratio: Double, resetAt: Date?, isKnown: Bool)) -> String {
        resolved.isKnown ? "\(Int((resolved.ratio * 100).rounded()))%" : "--"
    }

    var body: some View {
        let resolved = state

        VStack(alignment: .leading, spacing: isDense ? 4 : 5) {
            if isDense {
                Text(localizedTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Branding.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(localizedTitle)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(percentText(resolved: resolved))
                        .font(.system(size: 15.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(percentTextColor)
                        .monospacedDigit()
                        .lineLimit(1)

                    Text(text.string(.remaining))
                        .font(.system(size: 9.5, weight: .light))
                        .foregroundStyle(Branding.inkSubtle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizedTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Branding.inkMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .truncationMode(.tail)
                            .help(localizedTitle)

                        Text(text.string(.remaining))
                            .font(.system(size: 10, weight: .light))
                            .foregroundStyle(Branding.inkSubtle)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text(percentText(resolved: resolved))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(percentTextColor)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            RatioBar(
                value: resolved.isKnown ? resolved.ratio : 0,
                tint: tint,
                track: isExhausted ? Branding.dangerSoft : Branding.track
            )

            Text(detailText(resolved: resolved))
                .font(.system(size: isDense ? 9.5 : 10, weight: .light))
                .foregroundStyle(Branding.inkSubtle.opacity(0.90))
                .lineLimit(1)
                .minimumScaleFactor(isDense ? 0.85 : 1)
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

private struct MetricRing: View {
    let value: Double
    let tint: Color
    var track: Color = Branding.track

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, lineWidth: 3.6)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.55), value: value)
        }
    }
}

private struct RatioBar: View {
    let value: Double
    let tint: Color
    var track: Color = Branding.track

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)
                    .overlay(
                        Capsule()
                            .stroke(Branding.iconHighlight, lineWidth: 0.5)
                    )
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * value, value > 0 ? 7 : 0))
                    .animation(.easeOut(duration: 0.55), value: value)
            }
        }
        .frame(height: 7)
    }
}
