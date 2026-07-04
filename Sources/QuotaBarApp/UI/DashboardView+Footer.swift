import SwiftUI

// Footer bar, account filter menu, and empty states.
extension DashboardView {
    var footerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                isFilterMenuPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(text.string(.show))
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(Branding.inkSubtle.opacity(0.90))
                        .lineLimit(1)

                    Circle()
                        .fill(Branding.separatorDot)
                        .frame(width: 2.5, height: 2.5)

                    Text(currentFilterLabel)
                        .font(.system(size: 11.2, weight: .medium))
                        .foregroundStyle(Branding.inkMuted)
                        .lineLimit(1)

                    Text("\(currentFilterCount)")
                        .font(.system(size: 11.2, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Branding.inkMuted)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundStyle(Branding.inkSubtle.opacity(0.68))
                        .rotationEffect(.degrees(isFilterMenuPresented ? 180 : 0))
                }
                .padding(.leading, 9)
                .padding(.trailing, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                        .fill(Branding.controlSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                        .stroke(
                            isFilterMenuPresented ? Branding.accentBlue.opacity(0.10) : Branding.controlStroke.opacity(0.45),
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous))
                .animation(settingsPopoverAnimation, value: isFilterMenuPresented)
            }
            .buttonStyle(.quotaInteractive())
            .fixedSize()
            .help(currentFilterTitle)
            .accessibilityLabel(currentFilterTitle)
            .popover(isPresented: $isFilterMenuPresented, arrowEdge: .bottom) {
                VStack(spacing: 4) {
                    footerFilterOption(filter: .all) {
                        accountFilter = .all
                        isFilterMenuPresented = false
                    }

                    footerFilterOption(filter: .available) {
                        accountFilter = .available
                        isFilterMenuPresented = false
                    }
                }
                .padding(7)
                .frame(width: 168)
                .background(
                    RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                        .fill(Branding.menuSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous)
                        .stroke(Branding.borderSubtle, lineWidth: 0.75)
                )
                .shadow(color: Branding.shadowPopover, radius: 14, y: 6)
            }

            Spacer(minLength: 8)

            Button {
                NSApp.terminate(nil)
            } label: {
                Text(text.string(.quit))
                    .font(.system(size: 11.2, weight: .light))
                .foregroundStyle(Branding.inkSubtle.opacity(0.82))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(RoundedRectangle(cornerRadius: Branding.radiusMenu, style: .continuous))
            }
            .buttonStyle(.quotaInteractive())
            .help(text.string(.quit))
            .accessibilityLabel(text.string(.quit))
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(Branding.pageBackground.opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Branding.controlStroke.opacity(0.55))
                .frame(height: 0.75)
        }
    }
    var currentFilterTitle: String {
        accountFilter == .all
            ? text.accountFilterAll(count: toolAccounts.count)
            : text.accountFilterAvailable(count: availableAccountCount)
    }

    var currentFilterLabel: String {
        filterTitle(accountFilter)
    }

    var currentFilterCount: Int {
        filterCount(accountFilter)
    }

    func filterTitle(_ filter: AccountFilter) -> String {
        switch filter {
        case .all:
            return text.accountFilterAllTitle
        case .available:
            return text.accountFilterAvailableTitle
        }
    }

    func filterCount(_ filter: AccountFilter) -> Int {
        switch filter {
        case .all:
            return toolAccounts.count
        case .available:
            return availableAccountCount
        }
    }

    func filterAccessibilityTitle(_ filter: AccountFilter) -> String {
        switch filter {
        case .all:
            return text.accountFilterAll(count: toolAccounts.count)
        case .available:
            return text.accountFilterAvailable(count: availableAccountCount)
        }
    }

    func footerFilterOption(filter: AccountFilter, action: @escaping () -> Void) -> some View {
        let title = filterTitle(filter)
        let count = filterCount(filter)
        let isSelected = accountFilter == filter

        return Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Branding.accentBlueDark : Branding.inkStrong)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("\(count)")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Branding.accentBlueDark : Branding.inkSubtle)
                    .lineLimit(1)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Branding.accentBlueDark)
                        .frame(width: 12)
                } else {
                    Color.clear
                        .frame(width: 12, height: 1)
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
        .help(filterAccessibilityTitle(filter))
        .accessibilityLabel(filterAccessibilityTitle(filter))
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            ToolLogoIcon(tool: appState.selectedTool, size: 30)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(Branding.controlSurface)
                )
                .overlay(
                    Circle().stroke(Branding.controlStroke, lineWidth: 0.75)
                )
                .opacity(0.9)

            VStack(spacing: 6) {
                Text(text.string(.emptyAccountsTitle))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Branding.ink)

                Text(text.string(.emptyAccountsDescription))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Branding.inkMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 280)
            }

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
                .padding(.horizontal, 14)
                .frame(height: 32)
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
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    var filteredEmptyState: some View {
        VStack(spacing: 8) {
            Text(text.string(.emptyAvailableAccountsTitle))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Branding.inkMuted)

            Text(text.string(.emptyAvailableAccountsDescription))
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(Branding.inkSubtle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 58)
    }
}
