import SwiftUI

struct DashboardSettingsView: View {
    @ObservedObject var appState: AppState

    let preferredPanelHeight: CGFloat
    let settingsPopoverAnimation: Animation?
    let onClose: () -> Void

    private var text: AppText { appState.text }

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer()
                .frame(height: 6)

            ScrollView(.vertical, showsIndicators: false) {
                settingsPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .clipped()

            Spacer(minLength: DashboardLayout.bottomReserve)
        }
        .padding(.top, 8)
        .padding(.horizontal, 18)
        .frame(width: DashboardLayout.contentWidth, height: preferredPanelHeight, alignment: .top)
        .background(DashboardPanelBackground())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(text.string(.settings))
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(Branding.inkStrong)
                .lineLimit(1)

            Spacer(minLength: 10)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Branding.inkSubtle)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                            .fill(Branding.controlSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                            .stroke(Branding.controlStroke, lineWidth: 0.75)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous))
            }
            .buttonStyle(.quotaInteractive())
            .help(text.string(.cancel))
            .accessibilityLabel(text.string(.cancel))
        }
        .frame(height: 36, alignment: .center)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            topSettingsGroup

            settingsSection(title: text.string(.settingsMenuBar)) {
                Text(text.string(.menuBarToolsHint))
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Branding.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)

                ForEach(ToolKind.allCases) { tool in
                    menuBarToolRow(tool)
                }
            }

            settingsSection(title: text.string(.settingsRefresh)) {
                settingsToggleRow(
                    title: text.string(.refreshOnOpen),
                    iconName: "arrow.clockwise.circle",
                    isOn: refreshOnOpenBinding
                )
            }

            settingsSection(title: text.string(.settingsApp)) {
                settingsToggleRow(
                    title: text.string(.launchAtLogin),
                    iconName: "power.circle",
                    isOn: launchAtLoginBinding
                )

                settingsActionRow(
                    title: settingsUpdateActionTitle,
                    subtitle: settingsUpdateDetailTitle,
                    iconName: settingsUpdateIconName,
                    isEnabled: isSettingsUpdateActionEnabled,
                    showsBadge: shouldShowSettingsUpdateBadge
                ) {
                    runSettingsUpdateAction()
                }
            }
        }
        .padding(.bottom, 12)
    }

    private var topSettingsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsControlBlock(title: text.string(.language)) {
                languageSegmentedControl
            }

            settingsDivider

            settingsControlBlock(title: text.string(.recommendationStrategy)) {
                recommendationStrategySegmentedControl
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                .fill(Branding.controlSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                .stroke(Branding.controlStroke, lineWidth: 1)
        )
    }

    private func settingsControlBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11.2, weight: .semibold))
                .foregroundStyle(Branding.inkMuted)
                .padding(.leading, 2)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(Branding.controlStroke.opacity(0.76))
            .frame(height: 0.75)
            .padding(.vertical, 10)
    }

    private var languageSegmentedControl: some View {
        HStack(spacing: 4) {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    withAnimation(settingsPopoverAnimation) {
                        appState.setLanguage(language)
                    }
                } label: {
                    Text(language.displayName)
                        .font(.system(size: 11.5, weight: appState.language == language ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                        .frame(maxWidth: .infinity)
                        .frame(height: 29)
                        .foregroundStyle(appState.language == language ? Branding.accentBlueDark : Branding.inkMuted)
                        .background(
                            RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous)
                                .fill(appState.language == language ? Branding.menuItemSelectedSurface : Color.clear)
                        )
                }
                .buttonStyle(.quotaInteractive())
                .help(language.displayName)
                .accessibilityLabel(language.displayName)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Branding.radiusSegment, style: .continuous)
                .fill(Branding.controlSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Branding.radiusSegment, style: .continuous)
                .stroke(Branding.controlStroke, lineWidth: 1)
        )
        .animation(settingsPopoverAnimation, value: appState.language)
    }

    private var recommendationStrategySegmentedControl: some View {
        HStack(spacing: 4) {
            ForEach(AccountRecommendationStrategy.allCases) { strategy in
                Button {
                    withAnimation(settingsPopoverAnimation) {
                        appState.setRecommendationStrategy(strategy)
                    }
                } label: {
                    Text(text.recommendationStrategyTitle(strategy))
                        .font(.system(size: 11.2, weight: appState.recommendationStrategy == strategy ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .frame(maxWidth: .infinity)
                        .frame(height: 29)
                        .foregroundStyle(appState.recommendationStrategy == strategy ? Branding.accentBlueDark : Branding.inkMuted)
                        .background(
                            RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous)
                                .fill(appState.recommendationStrategy == strategy ? Branding.menuItemSelectedSurface : Color.clear)
                        )
                }
                .buttonStyle(.quotaInteractive())
                .help(text.recommendationStrategyTitle(strategy))
                .accessibilityLabel(text.recommendationStrategyTitle(strategy))
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Branding.radiusSegment, style: .continuous)
                .fill(Branding.controlSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Branding.radiusSegment, style: .continuous)
                .stroke(Branding.controlStroke, lineWidth: 1)
        )
        .animation(settingsPopoverAnimation, value: appState.recommendationStrategy)
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11.2, weight: .semibold))
                .foregroundStyle(Branding.inkMuted)
                .padding(.leading, 4)

            VStack(spacing: 3) {
                content()
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                    .fill(Branding.controlSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                    .stroke(Branding.controlStroke, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsToggleRow(
        title: String,
        subtitle: String? = nil,
        iconName: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                settingsRowIcon(iconName)

                settingsRowText(title: title, subtitle: subtitle, isEnabled: true)

                Spacer(minLength: 8)

                Toggle("", isOn: .constant(isOn.wrappedValue))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .allowsHitTesting(false)
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: subtitle == nil ? 36 : 48)
            .frame(maxWidth: .infinity)
            .background(settingsRowBackground)
        }
        .buttonStyle(.quotaInteractive())
        .help(title)
        .accessibilityLabel(title)
        .animation(settingsPopoverAnimation, value: isOn.wrappedValue)
    }

    private func menuBarToolRow(_ tool: ToolKind) -> some View {
        let isOn = appState.isToolVisibleInMenuBar(tool)
        return Button {
            withAnimation(settingsPopoverAnimation) {
                appState.setToolVisibleInMenuBar(tool, !appState.isToolVisibleInMenuBar(tool))
            }
        } label: {
            HStack(spacing: 8) {
                ToolLogoIcon(tool: tool, size: 15)
                    .frame(width: 15, height: 15)
                    .opacity(isOn ? 1 : 0.5)

                Text(tool.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isOn ? Branding.inkStrong : Branding.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)

                Spacer(minLength: 8)

                Toggle("", isOn: .constant(isOn))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .allowsHitTesting(false)
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(settingsRowBackground)
        }
        .buttonStyle(.quotaInteractive())
        .help(tool.displayName)
        .accessibilityLabel(tool.displayName)
        .animation(settingsPopoverAnimation, value: isOn)
    }

    private func settingsActionRow(
        title: String,
        subtitle: String? = nil,
        iconName: String,
        isEnabled: Bool,
        showsBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                settingsRowIcon(iconName)

                settingsRowText(title: title, subtitle: subtitle, isEnabled: isEnabled)

                Spacer(minLength: 8)

                if showsBadge {
                    Circle()
                        .fill(Branding.danger)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isEnabled ? Branding.inkSubtle : Branding.inkSubtle.opacity(0.48))
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .frame(height: subtitle == nil ? 36 : 48)
            .frame(maxWidth: .infinity)
            .background(settingsRowBackground)
            .opacity(isEnabled ? 1 : 0.68)
        }
        .buttonStyle(.quotaInteractive(isEnabled: isEnabled))
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private func settingsRowText(title: String, subtitle: String?, isEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? Branding.inkStrong : Branding.inkSubtle)
                .lineLimit(1)
                .minimumScaleFactor(0.88)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Branding.inkSubtle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsRowIcon(_ iconName: String) -> some View {
        Image(systemName: iconName)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Branding.inkMuted)
            .frame(width: 15)
    }

    private var settingsRowBackground: some View {
        RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous)
            .fill(Color.clear)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            appState.isLaunchAtLoginEnabled
        } set: { enabled in
            appState.setLaunchAtLoginEnabledFromDashboard(enabled)
        }
    }

    private var refreshOnOpenBinding: Binding<Bool> {
        Binding {
            appState.isRefreshOnOpenEnabled
        } set: { enabled in
            appState.setRefreshOnOpenEnabled(enabled)
        }
    }

    private var settingsUpdateActionTitle: String {
        switch appState.updateBannerState {
        case .available:
            return text.string(.downloadAndInstall)
        case .checking:
            return text.string(.checkingForUpdates)
        case .downloading:
            return text.string(.downloadingUpdate)
        case .installing:
            return text.string(.installingUpdate)
        case .idle:
            return text.string(.checkForUpdates)
        }
    }

    private var settingsUpdateDetailTitle: String {
        let current = text.currentVersionLabel(currentAppVersion)
        if case .available(let version) = appState.updateBannerState {
            return "\(current) · \(text.updateAvailableLabel(version))"
        }
        return current
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    private var shouldShowSettingsUpdateBadge: Bool {
        if case .available = appState.updateBannerState {
            return true
        }
        return false
    }

    private var settingsUpdateIconName: String {
        switch appState.updateBannerState {
        case .available:
            return "arrow.down.circle.fill"
        case .checking:
            return "magnifyingglass"
        case .downloading:
            return "arrow.down.circle"
        case .installing:
            return "gearshape.2"
        case .idle:
            return "arrow.down.circle"
        }
    }

    private var isSettingsUpdateActionEnabled: Bool {
        switch appState.updateBannerState {
        case .idle, .available:
            return true
        case .checking, .downloading, .installing:
            return false
        }
    }

    private func runSettingsUpdateAction() {
        switch appState.updateBannerState {
        case .available:
            appState.installAvailableUpdateFromDashboard()
        case .idle:
            appState.checkForUpdatesFromDashboard()
        case .checking, .downloading, .installing:
            break
        }
        onClose()
    }
}
