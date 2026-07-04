import SwiftUI

// Panel header: tool picker, add-account entry, refresh control, status line.
extension DashboardView {
    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                toolPickerButton

                Text(headerTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Branding.inkStrong)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 10)

                headerActions
            }

            headerStatus
        }
        .frame(height: DashboardLayout.headerHeight, alignment: .topLeading)
        .padding(.horizontal, 18)
    }

    var headerTitle: String {
        text.usageHeadline
    }

    var toolPickerButton: some View {
        Button {
            setSettingsMenuPresented(false)
            isToolMenuPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                ToolLogoIcon(tool: appState.selectedTool, size: toolPickerLogoSize(for: appState.selectedTool))
                    .frame(width: 22, height: 22)

                Text(appState.selectedTool.displayName)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Branding.inkStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                    .layoutPriority(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Branding.inkSubtle.opacity(0.72))
                    .rotationEffect(.degrees(isToolMenuPresented ? 180 : 0))
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .frame(height: 30)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                    .fill(Branding.controlSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                    .stroke(
                        isToolMenuPresented ? Branding.accentBlue.opacity(0.35) : Branding.separatorDot,
                        lineWidth: isToolMenuPresented ? 1 : 0.75
                    )
            )
            .shadow(color: Branding.shadowPopover.opacity(0.6), radius: 2.5, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous))
            .animation(settingsPopoverAnimation, value: isToolMenuPresented)
        }
        .buttonStyle(.quotaInteractive())
        .help(appState.selectedTool.displayName)
        .accessibilityLabel(appState.selectedTool.displayName)
        .popover(isPresented: $isToolMenuPresented, arrowEdge: .bottom) {
            VStack(spacing: 4) {
                ForEach(ToolKind.allCases) { tool in
                    toolPickerOption(tool)
                }
            }
            .padding(8)
            .frame(width: 184)
            .background(
                RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                    .fill(Branding.menuSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                    .stroke(Branding.borderSubtle, lineWidth: 0.75)
            )
            .shadow(color: Branding.shadowPopover, radius: 16, y: 6)
        }
    }

    func toolPickerOption(_ tool: ToolKind) -> some View {
        let isSelected = appState.selectedTool == tool

        return Button {
            isToolMenuPresented = false
            setSettingsMenuPresented(false)
            appState.selectTool(tool)
        } label: {
            HStack(spacing: 8) {
                ToolLogoIcon(tool: tool, size: toolPickerLogoSize(for: tool))
                    .frame(width: 20, height: 20)
                    .opacity(isSelected ? 1 : 0.62)

                Text(tool.displayName)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Branding.accentBlueDark : Branding.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                let toolAccountCount = appState.accounts(for: tool).count
                if toolAccountCount > 0 {
                    Text("\(toolAccountCount)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Branding.accentBlueDark.opacity(0.7) : Branding.inkSubtle)
                        .lineLimit(1)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Branding.accentBlueDark)
                } else {
                    Color.clear.frame(width: 9.5, height: 1)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                    .fill(isSelected ? Branding.menuItemSelectedSurface : Color.clear)
            )
        }
        .buttonStyle(.quotaInteractive())
        .help(tool.displayName)
        .accessibilityLabel(tool.displayName)
    }

    func toolPickerLogoSize(for tool: ToolKind) -> CGFloat {
        switch tool {
        case .codex:
            return 19
        case .cursor:
            return 18
        case .claudeCode:
            return 20
        }
    }

    @ViewBuilder
    var headerStatus: some View {
        HStack(spacing: 6) {
            if appState.isAddingAccount, let phase = appState.addAccountPhase {
                ProgressView()
                    .controlSize(.mini)

                Text(addAccountStatusText(phase))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Branding.accentBlueDark)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if phase == .waitingBrowserAuthorization, let deadline = loginProgress.deadline, deadline > Date() {
                    Text(timerInterval: Date() ... deadline, countsDown: true)
                        .font(.system(size: 10.5, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(Branding.inkSubtle)
                        .lineLimit(1)
                }

                if phase == .waitingBrowserAuthorization, loginProgress.canReopenAuthorizationPage {
                    Button {
                        loginProgress.reopenAuthorizationPage()
                    } label: {
                        Text(text.string(.reopenAuthPage))
                            .font(.system(size: 10.8, weight: .medium))
                            .foregroundStyle(Branding.accentBlueDark)
                            .underline()
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.quotaInteractive())
                    .help(text.string(.reopenAuthPage))
                    .accessibilityLabel(text.string(.reopenAuthPage))
                }
            } else {
                Text(text.string(.current))
                    .font(.system(size: 11.5, weight: .light))
                    .foregroundStyle(Branding.inkSubtle)

                Text(activeAccountName ?? "--")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Branding.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }

            Button {
                isToolMenuPresented = false
                setSettingsMenuPresented(!isSettingsMenuPresented)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isSettingsMenuPresented ? Branding.accentBlueDark : Branding.inkSubtle.opacity(0.62))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous)
                            .fill(isSettingsMenuPresented ? Branding.accentBlueSoft : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous))
            }
            .buttonStyle(.quotaInteractive())
            .help(text.string(.settings))
            .accessibilityLabel(text.string(.settings))
        }
        .frame(height: 22, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    // The waiting phase names the concrete method (browser vs device code) so multi-attempt
    // flows like Codex don't sit behind one generic message for minutes.
    private func addAccountStatusText(_ phase: AddAccountPhase) -> String {
        if phase == .waitingBrowserAuthorization, let method = loginProgress.method {
            return text.loginMethodPhaseText(method)
        }
        return text.addAccountPhaseText(phase)
    }

    func compactHeaderAccountName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "--" }
        if trimmed.count <= 28 {
            return trimmed
        }
        if let atIndex = trimmed.firstIndex(of: "@") {
            let localPart = String(trimmed[..<atIndex])
            let domainPart = String(trimmed[trimmed.index(after: atIndex)...])
            if localPart.count > 14 {
                return "\(localPart.prefix(14))...\(domainPart.isEmpty ? "" : "@\(domainPart)")"
            }
        }
        return "\(trimmed.prefix(24))..."
    }

    var headerActions: some View {
        HStack(spacing: 6) {
            headerRefreshButton

            Button {
                if appState.isAddingAccount {
                    appState.cancelAddAccount()
                } else {
                    appState.quickAddAccount(tool: appState.selectedTool)
                }
            } label: {
                HStack(spacing: 5) {
                    if appState.isAddingAccount {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Branding.warning)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }

                    Text(appState.isAddingAccount ? text.string(.cancelAdding) : text.string(.addAccount))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 11)
                .frame(width: 80, height: 30)
                .foregroundStyle(appState.isAddingAccount ? Branding.warning : Branding.accentBlueDark)
                .background(
                    RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                        .fill(appState.isAddingAccount ? Branding.warningSoft : Branding.accentBlueSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                        .stroke(
                            appState.isAddingAccount
                                ? Branding.warning.opacity(0.12)
                                : Branding.accentBlue.opacity(0.10),
                            lineWidth: 0.75
                        )
                )
            }
            .buttonStyle(.quotaInteractive())
            .help(appState.isAddingAccount ? text.string(.cancelAdding) : text.string(.addAccount))
            .accessibilityLabel(appState.isAddingAccount ? text.string(.cancelAdding) : text.string(.addAccount))
        }
        .frame(width: 120, height: 30, alignment: .trailing)
    }

    var headerRefreshButton: some View {
        let isBusy = isRefreshingSelectedTool
        let isEnabled = !isBusy && !toolAccounts.isEmpty

        return Button {
            guard isEnabled else { return }
            freezeCurrentAccountOrder()
            refreshCycleID += 1
            appState.refreshSelectedTool()
        } label: {
            HeaderRefreshGlyph(isRefreshing: isBusy)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(headerRefreshButtonTint(isEnabled: isEnabled, isBusy: isBusy))
                .opacity(isEnabled || isBusy ? 1 : 0.58)
                .frame(width: 32, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                        .fill(isBusy ? Branding.accentBlueSoft : Branding.controlSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                        .stroke(
                            isBusy ? Branding.accentBlue.opacity(0.12) : Branding.controlStroke,
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous))
        }
        .buttonStyle(.quotaInteractive(isEnabled: isEnabled || isBusy))
        .disabled(!isEnabled)
        .help(text.refreshAllAccounts(tool: appState.selectedTool))
        .accessibilityLabel(text.refreshAllAccounts(tool: appState.selectedTool))
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    func headerRefreshButtonTint(isEnabled: Bool, isBusy: Bool) -> Color {
        if isBusy {
            return Branding.accentBlueDark
        }
        return isEnabled ? Branding.inkMuted : Branding.inkSubtle
    }

}

private struct HeaderRefreshGlyph: View {
    let isRefreshing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if reduceMotion {
            Image(systemName: isRefreshing ? "arrow.clockwise.circle" : "arrow.clockwise")
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isRefreshing)) { context in
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefreshing ? rotationDegrees(at: context.date) : 0))
            }
        }
    }

    func rotationDegrees(at date: Date) -> Double {
        let duration = 0.85
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration
        return progress * 360
    }
}
