import SwiftUI

struct ResetCreditsDetailView: View {
    let inventory: QuotaResetCredits?
    let language: AppLanguage
    private var text: AppText { AppText(language: language) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(text.resetCreditsTitle).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    if let inventory {
                        Text(text.resetCreditsCount(inventory.remainingCount(at: context.date)))
                            .foregroundStyle(Branding.accentBlueDark)
                            .monospacedDigit()
                    }
                }
                if let inventory {
                    let credits = inventory.availableCredits(at: context.date)
                    if !credits.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                                    HStack {
                                        Text("\(index + 1)").foregroundStyle(Branding.inkMuted)
                                        Text(credit.expiresAt.map(text.creditExpiry) ?? text.expiryUnknown)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: Branding.radiusSmallControl).fill(Branding.controlSurface))
                                }
                            }
                        }
                        .frame(height: min(CGFloat(credits.count) * 44, 220))
                    } else if inventory.remainingCount(at: context.date) > 0 {
                        Text(text.expiryUnknown).foregroundStyle(Branding.inkMuted)
                    }
                    Text(text.updatedAt(inventory.updatedAt))
                        .font(.caption2).foregroundStyle(Branding.inkMuted)
                        .help(text.exactReset(inventory.updatedAt))
                } else {
                    Text(text.resetCreditsUnavailable).foregroundStyle(Branding.inkMuted)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Branding.inkStrong)
            .padding(14)
            .frame(width: 320)
            .background(Branding.pageBackground)
        }
    }
}
