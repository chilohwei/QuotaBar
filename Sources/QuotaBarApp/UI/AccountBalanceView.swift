import SwiftUI

struct AccountBalanceMetricView: View {
    let balance: AccountBalance?
    let isRefreshing: Bool
    let isStale: Bool
    let text: AppText

    var body: some View {
        let amount = balance?.primary
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(text.balanceTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Branding.inkMuted)
                Spacer(minLength: 12)
                Text(amount.map { $0.formatted($0.total, locale: text.language.locale) } ?? "--")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(valueTint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if isRefreshing {
                Text(text.string(.refreshing))
                    .font(.system(size: 10.2))
                    .foregroundStyle(Branding.inkSubtle)
            } else if let balance, !balance.isAvailable, !balance.isExhausted {
                Text(text.balanceUnavailable)
                    .font(.system(size: 10.2))
                    .foregroundStyle(Branding.warning)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        .opacity(isStale ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private var valueTint: Color {
        guard let balance, balance.primary != nil else { return Branding.inkSubtle }
        if balance.isExhausted { return Branding.danger }
        if !balance.isAvailable { return Branding.warning }
        return Branding.inkStrong
    }
}

struct AccountBalanceDetailsView: View {
    let balance: AccountBalance
    let text: AppText

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text.balanceDetails)
                .font(.system(size: 13, weight: .semibold))

            ForEach(balance.amounts) { amount in
                VStack(alignment: .leading, spacing: 5) {
                    row(amount.currency, amount.formatted(amount.total, locale: text.language.locale))
                    row(text.toppedUpBalance, amount.formatted(amount.toppedUp, locale: text.language.locale))
                    row(text.grantedBalance, amount.formatted(amount.granted, locale: text.language.locale))
                }
                .padding(9)
                .background(Branding.controlSurface, in: RoundedRectangle(cornerRadius: Branding.radiusMenu))
            }
        }
        .padding(12)
        .frame(width: 240)
        .foregroundStyle(Branding.ink)
        .background(Branding.menuSurface)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Branding.inkMuted)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }
}
