import SwiftUI

/// Local countdown only: rendering never polls a provider or invents a recovered balance.
struct QuotaResetDetail: View {
    let resetAt: Date?
    let language: AppLanguage
    var isKnown = true
    var fallbackDetail: String?
    var usesInlineLayout = false
    private var text: AppText { AppText(language: language) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Group {
                if usesInlineLayout {
                    HStack(spacing: 6) {
                        resetContent(now: context.date)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        resetContent(now: context.date)
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func resetContent(now: Date) -> some View {
        if let resetAt {
            Text(text.resetCountdown(resetAt, now: now))
                .font(.system(size: 10.8, weight: .medium))
                .foregroundStyle(Branding.inkMuted)
                .monospacedDigit()
            if usesInlineLayout {
                Text("·")
                    .font(.system(size: 10.2, weight: .regular))
                    .foregroundStyle(Branding.separatorDot)
            }
            Text(text.exactReset(resetAt))
                .font(.system(size: 10.2, weight: .regular))
                .foregroundStyle(Branding.inkSubtle)
                .monospacedDigit()
        } else {
            Text(isKnown ? text.resetUnavailable : (fallbackDetail ?? text.string(.waitingData)))
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(Branding.inkSubtle)
        }
    }
}
