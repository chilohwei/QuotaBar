import SwiftUI

/// Local countdown only: rendering never polls a provider or invents a recovered balance.
struct QuotaResetDetail: View {
    let resetAt: Date?
    let language: AppLanguage
    var isKnown = true
    var fallbackDetail: String?
    private var text: AppText { AppText(language: language) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 2) {
                if let resetAt {
                    Text(text.resetCountdown(resetAt, now: context.date))
                    Text(text.exactReset(resetAt))
                        .foregroundStyle(Branding.inkSubtle)
                } else {
                    Text(isKnown ? text.resetUnavailable : (fallbackDetail ?? text.string(.waitingData)))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Branding.inkMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
