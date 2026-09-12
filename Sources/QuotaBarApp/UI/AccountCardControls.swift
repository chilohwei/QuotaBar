import SwiftUI

struct CardTextActionButton: View {
    let title: String
    let tint: Color
    let softTint: Color
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    // Keep secondary card actions quiet; hover adds only a soft affordance.
    private var textColor: Color {
        if !isEnabled {
            return Branding.inkSubtle.opacity(0.5)
        }
        if !isHovering {
            return tint.opacity(0.90)
        }
        return tint
    }

    private var backgroundColor: Color {
        guard isEnabled, isHovering else { return .clear }
        return softTint.opacity(0.62)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.8, weight: .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 22)
                .foregroundStyle(textColor)
                .background(
                    RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous))
        }
        .buttonStyle(.quotaInteractive(isEnabled: isEnabled))
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

struct InlineMetadataLabel: View {
    let text: String
    let tint: Color
    let weight: Font.Weight

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: weight))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(tint)
    }
}

/// Quiet secondary controls; the blue selected state connects each button to its popover.
struct QuotaDetailButtonLabel: View {
    let title: String
    let isPresented: Bool
    var showsChevron = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .lineLimit(1)
                .monospacedDigit()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(isPresented ? Branding.accentBlueDark : Branding.inkSubtle)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(isPresented ? Branding.accentBlueDark : Branding.inkMuted)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous)
                .fill(isPresented ? Branding.accentBlueSoft : Branding.controlSurface.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous)
                .stroke(isPresented ? Branding.accentBlue.opacity(0.22) : Branding.separatorDot.opacity(0.65), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous))
    }
}
