import SwiftUI

// Top notice slot: transient toasts, restart hint, and update banner.
extension DashboardView {
    enum TopNotice {
        case addAccountError(String)
        case transient(TransientNotice)
        case restartRequired(String)
        case update
    }

    var topNotice: TopNotice? {
        if let message = appState.addAccountErrorMessage {
            return .addAccountError(message)
        }
        if let notice = appState.transientNotice {
            return .transient(notice)
        }
        if let message = appState.restartRequiredMessage {
            return .restartRequired(message)
        }
        if shouldShowUpdateNotice {
            return .update
        }
        return nil
    }

    @ViewBuilder
    func topNoticeBar(_ notice: TopNotice) -> some View {
        switch notice {
        case .addAccountError(let message):
            dismissableNoticeBar(
                message: message,
                iconName: "exclamationmark.triangle.fill",
                tint: Branding.danger,
                background: Branding.dangerSoft,
                onDismiss: { appState.dismissAddAccountError() }
            )
        case .transient(let transient):
            dismissableNoticeBar(
                message: transient.message,
                iconName: "checkmark.circle.fill",
                tint: Branding.success,
                background: Branding.successSoft,
                actionTitle: transient.actionTitle,
                onAction: { appState.performTransientNoticeAction() },
                onDismiss: { appState.dismissTransientNotice() }
            )
        case .restartRequired(let message):
            dismissableNoticeBar(
                message: message,
                iconName: "arrow.triangle.2.circlepath",
                tint: Branding.accentBlueDark,
                background: Branding.accentBlueSoft,
                actionTitle: appState.canRestartTool ? text.string(.restartNow) : nil,
                onAction: { appState.restartRequiredToolNow() },
                onDismiss: { appState.dismissRestartRequiredMessage() }
            )
        case .update:
            updateNoticeBar
        }
    }

    func dismissableNoticeBar(
        message: String,
        iconName: String,
        tint: Color,
        background: Color,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 16)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let actionTitle, let onAction {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(.system(size: 11.2, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(height: 23)
                        .foregroundStyle(tint)
                        .background(
                            RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                                .fill(Branding.controlSurface.opacity(0.76))
                        )
                }
                .buttonStyle(.quotaInteractive())
                .help(actionTitle)
                .accessibilityLabel(actionTitle)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.72))
                    .frame(width: 20, height: 20)
                    .contentShape(RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous))
            }
            .buttonStyle(.quotaInteractive())
            .help(text.string(.ok))
            .accessibilityLabel(text.string(.ok))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: DashboardLayout.updateNoticeHeight)
        .frame(maxWidth: .infinity)
        .foregroundStyle(tint)
        .background(
            RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
        .help(message)
        .accessibilityLabel(message)
    }

    var shouldShowUpdateNotice: Bool {
        if case .idle = appState.updateBannerState {
            return false
        }
        return true
    }

    var updateNoticeBar: some View {
        HStack(spacing: 10) {
            Image(systemName: updateNoticeIconName)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 16)

            Text(updateNoticeTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .monospacedDigit()

            Spacer(minLength: 8)

            if isUpdateNoticeEnabled {
                Button {
                    appState.ignoreAvailableUpdateFromDashboard()
                } label: {
                    Text(text.string(.ignore))
                        .font(.system(size: 11.2, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(height: 23)
                        .foregroundStyle(Branding.accentBlueDark.opacity(0.72))
                        .background(
                            RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                                .fill(Branding.controlSurface.opacity(0.76))
                        )
                }
                .buttonStyle(.quotaInteractive())
                .help(text.string(.ignore))
                .accessibilityLabel(text.string(.ignore))

                Button {
                    appState.installAvailableUpdateFromDashboard()
                } label: {
                    Text(text.string(.update))
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 23)
                        .foregroundStyle(Branding.primaryActionText)
                        .background(
                            RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                                .fill(Branding.accentBlue)
                        )
                }
                .buttonStyle(.quotaInteractive())
                .help(text.string(.update))
                .accessibilityLabel(text.string(.update))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, isUpdateNoticeEnabled ? 8 : 12)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .foregroundStyle(updateNoticeTint)
        .background(
            RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                .fill(updateNoticeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                .stroke(updateNoticeTint.opacity(0.14), lineWidth: 1)
        )
        .help(updateNoticeTitle)
        .accessibilityLabel(updateNoticeTitle)
        .opacity(isUpdateNoticeEnabled ? 1 : 0.94)
    }

    var isUpdateNoticeEnabled: Bool {
        if case .available = appState.updateBannerState {
            return true
        }
        return false
    }

    var updateNoticeIconName: String {
        switch appState.updateBannerState {
        case .available:
            return "arrow.down.circle.fill"
        case .checking:
            return "magnifyingglass"
        case .downloading:
            return "arrow.down.circle"
        case .installing:
            return "gearshape.2.fill"
        case .idle:
            return "arrow.down.circle"
        }
    }

    var updateNoticeTitle: String {
        text.updateNoticeTitle(appState.updateBannerState)
    }

    var updateNoticeTint: Color {
        switch appState.updateBannerState {
        case .available:
            return Branding.accentBlueDark
        case .checking, .downloading:
            return Branding.warning
        case .installing:
            return Branding.success
        case .idle:
            return Branding.inkMuted
        }
    }

    var updateNoticeBackground: Color {
        switch appState.updateBannerState {
        case .available:
            return Branding.accentBlueSoft
        case .checking, .downloading:
            return Branding.warningSoft
        case .installing:
            return Branding.successSoft
        case .idle:
            return Branding.chipSurface
        }
    }
}
