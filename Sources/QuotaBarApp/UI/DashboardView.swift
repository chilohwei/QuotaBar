import AppKit
import SwiftUI

enum DashboardLayout {
    static let panelWidth: CGFloat = 430
    static let fixedPanelHeight: CGFloat = 620
    static let accountCardHeight: CGFloat = 154
    static let accountCardSpacing: CGFloat = 10
    static let maxVisibleAccountCards = 3
    static let headerHeight: CGFloat = 60
    static let footerHeight: CGFloat = 28
    static let stackSpacing: CGFloat = 10
    static let headerListSpacing: CGFloat = 12
    static let listFooterSpacing: CGFloat = 8
    static let bottomReserve: CGFloat = 12
    static let updateNoticeHeight: CGFloat = 36
    static let settingsPanelWidth: CGFloat = 252
    static let settingsPopoverMargin: CGFloat = 12
    static let settingsPopoverGap: CGFloat = 7

    static var maxAccountListHeight: CGFloat {
        CGFloat(maxVisibleAccountCards) * accountCardHeight
            + CGFloat(maxVisibleAccountCards - 1) * accountCardSpacing
    }

    static var panelSize: NSSize {
        NSSize(width: panelWidth, height: fixedPanelHeight)
    }

    static let accountListHeight = maxAccountListHeight
}

struct DashboardView: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var accountFilter: AccountFilter = .all
    @State private var refreshCycleID: Int = 0
    @State private var isToolMenuPresented: Bool = false
    @State private var isFilterMenuPresented: Bool = false
    @State private var isSettingsMenuPresented: Bool = false
    @State private var frozenAccountOrderByTool: [ToolKind: [UUID]] = [:]
    @State private var lastVisibleAccountOrderByTool: [ToolKind: [UUID]] = [:]

    private var text: AppText { appState.text }

    private var toolAccounts: [Account] {
        appState.accounts(for: appState.selectedTool)
    }

    private var visibleAccounts: [Account] {
        let sortedAccounts = AccountListPresenter.visibleAccounts(
            accounts: toolAccounts,
            filter: accountFilter,
            activeID: appState.activeAccountByTool[appState.selectedTool],
            quotaByAccount: appState.quotaByAccount,
            loadStateByAccount: appState.loadStateByAccount,
            frozenOrder: effectiveFrozenOrder,
            recommendationStrategy: appState.recommendationStrategy
        )
        guard isRefreshingSelectedTool,
              let frozenOrder = effectiveFrozenOrder,
              !frozenOrder.isEmpty else {
            return sortedAccounts
        }

        let accountByID = Dictionary(uniqueKeysWithValues: toolAccounts.map { ($0.id, $0) })
        let frozenAccounts = frozenOrder.compactMap { accountByID[$0] }
        return frozenAccounts.isEmpty ? sortedAccounts : frozenAccounts
    }

    private var visibleAccountIDs: [UUID] {
        visibleAccounts.map(\.id)
    }

    private var preferredPanelHeight: CGFloat {
        DashboardLayout.fixedPanelHeight
    }

    private var accountListHeight: CGFloat {
        let updateNoticeReserve = shouldShowUpdateNotice
            ? DashboardLayout.updateNoticeHeight + DashboardLayout.stackSpacing
            : 0
        let minimumUsefulHeight = CGFloat(DashboardLayout.maxVisibleAccountCards - 1) * DashboardLayout.accountCardHeight
            + CGFloat(DashboardLayout.maxVisibleAccountCards - 2) * DashboardLayout.accountCardSpacing
        return max(DashboardLayout.accountListHeight - updateNoticeReserve, minimumUsefulHeight)
    }

    private var isRefreshingSelectedTool: Bool {
        toolAccounts.contains { account in
            appState.loadStateByAccount[account.id] == .refreshing
                || appState.loadStateByAccount[account.id] == .loadingInitial
        }
    }

    private var availableAccountCount: Int {
        AccountListPresenter.availableAccountCount(
            accounts: toolAccounts,
            quotaByAccount: appState.quotaByAccount
        )
    }

    private var activeAccountName: String? {
        appState.activeAccount(for: appState.selectedTool).map { compactHeaderAccountName($0.name) }
    }

    private var recommendedAccountID: UUID? {
        AccountListPresenter.recommendedAccountID(
            accounts: toolAccounts,
            activeID: appState.activeAccountByTool[appState.selectedTool],
            quotaByAccount: appState.quotaByAccount,
            loadStateByAccount: appState.loadStateByAccount,
            recommendationStrategy: appState.recommendationStrategy
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                header
                if shouldShowUpdateNotice {
                    Spacer()
                        .frame(height: DashboardLayout.stackSpacing)
                    updateNoticeBar
                }
                Spacer()
                    .frame(height: DashboardLayout.headerListSpacing)
                accountList
                Spacer()
                    .frame(height: DashboardLayout.listFooterSpacing)
                footerBar
                Spacer(minLength: DashboardLayout.bottomReserve)
            }
            .padding(.top, 8)
            .padding(.horizontal, 18)

        }
        .frame(width: DashboardLayout.panelWidth, height: preferredPanelHeight, alignment: .top)
        .overlayPreferenceValue(SettingsButtonAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if isSettingsMenuPresented {
                    ZStack(alignment: .topLeading) {
                        settingsDismissLayer
                            .zIndex(9)

                        if let anchor {
                            settingsPopover(anchorFrame: proxy[anchor])
                                .zIndex(10)
                        }
                    }
                }
            }
        }
        .background(Branding.pageBackground)
        .foregroundStyle(Branding.ink)
        .alert(text.string(.restartRequiredTitle), isPresented: restartRequiredAlertBinding) {
            Button(text.string(.ok)) {
                appState.dismissRestartRequiredMessage()
            }
        } message: {
            Text(appState.restartRequiredMessage ?? "")
        }
        .alert(text.string(.addAccountFailedTitle), isPresented: addAccountErrorAlertBinding) {
            Button(text.string(.ok)) {
                appState.dismissAddAccountError()
            }
        } message: {
            Text(appState.addAccountErrorMessage ?? "")
        }
        .onChange(of: isRefreshingSelectedTool) { refreshing in
            if refreshing {
                if frozenAccountOrderByTool[appState.selectedTool] == nil {
                    frozenAccountOrderByTool[appState.selectedTool] = preferredFrozenOrderForSelectedTool()
                }
            } else {
                withTransaction(Transaction(animation: nil)) {
                    frozenAccountOrderByTool[appState.selectedTool] = nil
                    rememberVisibleOrderForSelectedTool(visibleAccountIDs)
                }
            }
        }
        .onChange(of: visibleAccountIDs) { ids in
            guard !isRefreshingSelectedTool else { return }
            rememberVisibleOrderForSelectedTool(ids)
        }
        .onChange(of: appState.selectedTool) { _ in
            rememberVisibleOrderForSelectedTool(visibleAccountIDs)
        }
        .onAppear {
            rememberVisibleOrderForSelectedTool(visibleAccountIDs)
        }
    }

    private func freezeCurrentAccountOrder() {
        let ids = visibleAccountIDs
        frozenAccountOrderByTool[appState.selectedTool] = ids
        rememberVisibleOrderForSelectedTool(ids)
    }

    private var effectiveFrozenOrder: [UUID]? {
        let tool = appState.selectedTool
        if let frozen = frozenAccountOrderByTool[tool] {
            return activeFirstOrder(frozen)
        }
        if isRefreshingSelectedTool,
           let remembered = lastVisibleAccountOrderByTool[tool],
           !remembered.isEmpty {
            return activeFirstOrder(remembered)
        }
        return nil
    }

    private func preferredFrozenOrderForSelectedTool() -> [UUID] {
        let tool = appState.selectedTool
        if let remembered = lastVisibleAccountOrderByTool[tool], !remembered.isEmpty {
            return activeFirstOrder(remembered)
        }
        return activeFirstOrder(visibleAccountIDs)
    }

    private func rememberVisibleOrderForSelectedTool(_ ids: [UUID]) {
        lastVisibleAccountOrderByTool[appState.selectedTool] = activeFirstOrder(ids)
    }

    private func activeFirstOrder(_ ids: [UUID]) -> [UUID] {
        guard let activeID = appState.activeAccountByTool[appState.selectedTool],
              ids.contains(activeID) else {
            return ids
        }
        return [activeID] + ids.filter { $0 != activeID }
    }

    private func accountLoadState(_ account: Account) -> AccountLoadState {
        appState.loadStateByAccount[account.id] ?? .idle
    }

    private func isAccountRefreshing(_ account: Account) -> Bool {
        let state = accountLoadState(account)
        return state == .refreshing || state == .loadingInitial
    }

    private func setSettingsMenuPresented(_ isPresented: Bool) {
        withAnimation(settingsPopoverAnimation) {
            isSettingsMenuPresented = isPresented
        }
    }

    private var settingsPopoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    toolSwitchMenu
                    Text(text.usageHeadline)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Branding.inkStrong)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                headerActions
            }

            headerStatus
        }
        .frame(height: DashboardLayout.headerHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var headerStatus: some View {
        HStack(spacing: 6) {
            Text(text.string(.current))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Branding.inkMuted)

            Text(activeAccountName ?? "--")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Branding.inkStrong.opacity(0.74))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            headerSettingsButton
                .fixedSize()
        }
        .frame(height: 20, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var headerSettingsButton: some View {
        Button {
            setSettingsMenuPresented(!isSettingsMenuPresented)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isSettingsMenuPresented ? Branding.accentBlueDark : Branding.inkMuted)
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(isSettingsMenuPresented ? Branding.accentBlueSoft : Branding.controlSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .stroke(
                            isSettingsMenuPresented ? Branding.accentBlue.opacity(0.18) : Branding.controlStroke,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        }
        .buttonStyle(.quotaInteractive())
        .help(text.string(.settings))
        .accessibilityLabel(text.string(.settings))
        .anchorPreference(key: SettingsButtonAnchorKey.self, value: .bounds) { $0 }
    }

    private func compactHeaderAccountName(_ value: String) -> String {
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

    private var headerActions: some View {
        HStack(spacing: 8) {
            headerRefreshButton

            Button {
                if appState.isAddingAccount {
                    appState.cancelAddAccount()
                } else {
                    appState.quickAddAccount(tool: appState.selectedTool)
                }
            } label: {
                HStack(spacing: 6) {
                    if appState.isAddingAccount {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Branding.warning)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 11.5, weight: .bold))
                    }

                    Text(appState.isAddingAccount ? text.string(.cancelAdding) : text.string(.addAccount))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 12)
                .frame(width: 82, height: 32)
                .foregroundStyle(appState.isAddingAccount ? Branding.warning : Branding.accentBlueDark)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(appState.isAddingAccount ? Branding.warningSoft : Branding.accentBlueSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            appState.isAddingAccount
                                ? Branding.warning.opacity(0.16)
                                : Branding.accentBlue.opacity(0.14),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.quotaInteractive())
            .help(appState.isAddingAccount ? text.string(.cancelAdding) : text.string(.addAccount))
            .accessibilityLabel(appState.isAddingAccount ? text.string(.cancelAdding) : text.string(.addAccount))
        }
        .frame(width: 126, height: 32, alignment: .trailing)
    }

    private var headerRefreshButton: some View {
        let isBusy = isRefreshingSelectedTool
        let isEnabled = !isBusy && !toolAccounts.isEmpty

        return Button {
            guard isEnabled else { return }
            freezeCurrentAccountOrder()
            refreshCycleID += 1
            appState.refreshSelectedTool()
        } label: {
            HeaderRefreshGlyph(isRefreshing: isBusy)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(headerRefreshButtonTint(isEnabled: isEnabled, isBusy: isBusy))
                .opacity(isEnabled || isBusy ? 1 : 0.58)
                .frame(width: 36, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isBusy ? Branding.accentBlueSoft : Branding.controlSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isBusy ? Branding.accentBlue.opacity(0.18) : Branding.controlStroke,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.quotaInteractive(isEnabled: isEnabled || isBusy))
        .disabled(!isEnabled)
        .help(text.refreshAllAccounts(tool: appState.selectedTool))
        .accessibilityLabel(text.refreshAllAccounts(tool: appState.selectedTool))
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func headerRefreshButtonTint(isEnabled: Bool, isBusy: Bool) -> Color {
        if isBusy {
            return Branding.accentBlueDark
        }
        return isEnabled ? Branding.inkMuted : Branding.inkSubtle
    }

    private var toolSwitchMenu: some View {
        Button {
            isToolMenuPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(toolBackground(appState.selectedTool))
                    ToolLogoIcon(tool: appState.selectedTool, size: 11.5)
                }
                .frame(width: 18, height: 18)

                Text(appState.selectedTool.displayName)
                    .font(.system(size: 15.5, weight: .semibold, design: .rounded))

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Branding.inkSubtle)
            }
            .foregroundStyle(Branding.inkStrong)
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Branding.controlSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Branding.controlStroke, lineWidth: 1)
            )
        }
        .popover(isPresented: $isToolMenuPresented, arrowEdge: .top) {
            VStack(spacing: 4) {
                ForEach(ToolKind.allCases) { tool in
                    Button {
                        appState.selectTool(tool)
                        isToolMenuPresented = false
                    } label: {
                        HStack(spacing: 9) {
                            ZStack {
                                Circle()
                                    .fill(toolBackground(tool))
                                ToolLogoIcon(tool: tool, size: 11)
                            }
                            .frame(width: 18, height: 18)

                            Text(tool.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Branding.inkStrong)
                                .lineLimit(1)
                                .layoutPriority(1)

                            Spacer(minLength: 6)

                            if appState.selectedTool == tool {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(toolTint(tool))
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 31)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(appState.selectedTool == tool ? Branding.menuItemSelectedSurface : Color.clear)
                        )
                    }
                    .buttonStyle(.quotaInteractive())
                    .help(tool.displayName)
                    .accessibilityLabel(tool.displayName)
                }
            }
            .padding(8)
            .frame(width: 178)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Branding.menuSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Branding.borderSubtle, lineWidth: 1)
            )
            .shadow(color: Branding.shadowPopover, radius: 18, y: 8)
        }
        .buttonStyle(.quotaInteractive())
        .help(appState.selectedTool.displayName)
        .accessibilityLabel(appState.selectedTool.displayName)
        .fixedSize()
    }

    private func toolTint(_ tool: ToolKind) -> Color {
        switch tool {
        case .codex:
            return Branding.accentBlueDark
        case .cursor:
            return Branding.success
        case .claudeCode:
            return Branding.warning
        }
    }

    private func toolBackground(_ tool: ToolKind) -> Color {
        switch tool {
        case .codex:
            return Branding.accentBlueSoft.opacity(0.72)
        case .cursor:
            return Branding.successSoft.opacity(0.70)
        case .claudeCode:
            return Branding.warningSoft.opacity(0.72)
        }
    }

    @ViewBuilder
    private var accountList: some View {
        let accounts = visibleAccounts
        let listHeight = accountListHeight

        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    ScrollIndicatorHider()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)

                    if toolAccounts.isEmpty {
                        emptyState
                    } else if accounts.isEmpty {
                        filteredEmptyState
                    } else {
                        LazyVStack(spacing: DashboardLayout.accountCardSpacing) {
                            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                                AccountCardView(
                                    account: account,
                                    language: appState.language,
                                    isActive: appState.activeAccountByTool[appState.selectedTool] == account.id,
                                    isRecommended: recommendedAccountID == account.id,
                                    recommendationReason: recommendationReason(for: account),
                                    isRefreshing: isAccountRefreshing(account),
                                    loadState: accountLoadState(account),
                                    quota: appState.quotaByAccount[account.id],
                                    errorMessage: appState.errorByAccount[account.id],
                                    canActivate: true,
                                    isPrimaryVisibleCard: index == 0,
                                    refreshCycleID: refreshCycleID,
                                    onActivate: { appState.activateAccount(account) },
                                    onRefresh: { appState.refreshAccount(account) },
                                    onDelete: { appState.deleteAccount(account) }
                                )
                                .transaction { transaction in
                                    if isRefreshingSelectedTool {
                                        transaction.animation = nil
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .id(AccountListScrollTarget.top)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.never, axes: .vertical)
            .clipped()
            .frame(height: listHeight)
            .frame(maxWidth: .infinity)
            .onChange(of: refreshCycleID) { _ in
                scrollAccountListToTop(using: scrollProxy)
            }
        }
    }

    private func recommendationReason(for account: Account) -> String {
        let reasonStrategy = AccountListPresenter.recommendationReasonStrategy(
            for: account,
            quotaByAccount: appState.quotaByAccount,
            recommendationStrategy: appState.recommendationStrategy
        )
        return text.recommendationReason(strategy: reasonStrategy)
    }

    private func scrollAccountListToTop(using scrollProxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.22)) {
                scrollProxy.scrollTo(AccountListScrollTarget.top, anchor: .top)
            }
        }
    }

    private var restartRequiredAlertBinding: Binding<Bool> {
        Binding {
            appState.restartRequiredMessage != nil
        } set: { isPresented in
            if !isPresented {
                appState.dismissRestartRequiredMessage()
            }
        }
    }

    private var addAccountErrorAlertBinding: Binding<Bool> {
        Binding {
            appState.addAccountErrorMessage != nil
        } set: { isPresented in
            if !isPresented {
                appState.dismissAddAccountError()
            }
        }
    }

    private var footerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                isFilterMenuPresented.toggle()
            } label: {
                HStack(spacing: 7) {
                    Text(text.string(.show))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Branding.inkMuted)

                    Circle()
                        .fill(Branding.separatorDot)
                        .frame(width: 3, height: 3)

                    Text(currentFilterTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Branding.inkStrong.opacity(0.68))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Branding.inkSubtle)
                }
                .padding(.leading, 9)
                .padding(.trailing, 8)
                .frame(height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Branding.controlSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Branding.controlStroke, lineWidth: 1)
                )
            }
            .buttonStyle(.quotaInteractive())
            .fixedSize()
            .help(currentFilterTitle)
            .accessibilityLabel(currentFilterTitle)
            .popover(isPresented: $isFilterMenuPresented, arrowEdge: .bottom) {
                VStack(spacing: 4) {
                    footerFilterOption(
                        title: text.accountFilterAll(count: toolAccounts.count),
                        isSelected: accountFilter == .all
                    ) {
                        accountFilter = .all
                        isFilterMenuPresented = false
                    }

                    footerFilterOption(
                        title: text.accountFilterAvailable(count: availableAccountCount),
                        isSelected: accountFilter == .available
                    ) {
                        accountFilter = .available
                        isFilterMenuPresented = false
                    }
                }
                .padding(8)
                .frame(width: 160)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Branding.menuSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Branding.borderSubtle, lineWidth: 1)
                )
                .shadow(color: Branding.shadowPopover, radius: 18, y: 8)
            }

            Spacer(minLength: 6)

            Button(text.string(.quit)) {
                NSApp.terminate(nil)
            }
            .font(.system(size: 11.5, weight: .regular))
            .foregroundStyle(Branding.inkMuted.opacity(0.92))
            .buttonStyle(.quotaInteractive())
            .help(text.string(.quit))
            .accessibilityLabel(text.string(.quit))
            .padding(.horizontal, 4)
            .frame(height: 23)
        }
        .padding(.top, 2)
        .frame(height: 28)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSection(title: text.string(.settingsDisplay)) {
                languageSegmentedControl

                settingsToggleRow(
                    title: text.string(.menuBarQuotaText),
                    iconName: "gauge.with.dots.needle.50percent",
                    isOn: statusBarQuotaTextBinding
                )
            }

            settingsSection(title: text.string(.settingsRecommendation)) {
                recommendationStrategyControl
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
                    iconName: settingsUpdateIconName,
                    isEnabled: isSettingsUpdateActionEnabled
                ) {
                    runSettingsUpdateAction()
                }
            }
        }
        .padding(10)
        .frame(width: DashboardLayout.settingsPanelWidth)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Branding.menuSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Branding.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Branding.shadowPopover, radius: 18, y: 8)
    }

    private var settingsDismissLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                setSettingsMenuPresented(false)
            }
    }

    private func settingsPopover(anchorFrame: CGRect) -> some View {
        let panelX = settingsPopoverX(anchorFrame: anchorFrame)
        let arrowLeading = settingsPopoverArrowLeading(anchorFrame: anchorFrame, panelX: panelX)

        return VStack(alignment: .leading, spacing: 0) {
            PopoverArrowShape()
                .fill(Branding.menuSurface)
                .frame(width: 22, height: 10)
                .overlay(
                    PopoverArrowShape()
                        .stroke(Branding.borderSubtle, lineWidth: 1)
                )
                .padding(.leading, arrowLeading)
                .zIndex(2)

            settingsPanel
                .offset(y: -1)
                .zIndex(1)
        }
        .frame(width: DashboardLayout.settingsPanelWidth, alignment: .leading)
        .offset(
            x: panelX,
            y: anchorFrame.maxY + DashboardLayout.settingsPopoverGap
        )
        .transition(settingsPopoverTransition(anchorFrame: anchorFrame))
        .animation(settingsPopoverAnimation, value: isSettingsMenuPresented)
    }

    private func settingsPopoverTransition(anchorFrame: CGRect) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        let panelX = settingsPopoverX(anchorFrame: anchorFrame)
        let anchorX = UnitPoint(
            x: min(max((anchorFrame.midX - panelX) / DashboardLayout.settingsPanelWidth, 0), 1),
            y: 0
        )
        return .asymmetric(
            insertion: .scale(scale: 0.985, anchor: anchorX).combined(with: .opacity),
            removal: .opacity
        )
    }

    private func settingsPopoverX(anchorFrame: CGRect) -> CGFloat {
        let preferredX = anchorFrame.midX - DashboardLayout.settingsPanelWidth / 2
        let minimumX = DashboardLayout.settingsPopoverMargin
        let maximumX = DashboardLayout.panelWidth - DashboardLayout.settingsPanelWidth - DashboardLayout.settingsPopoverMargin
        return min(max(preferredX, minimumX), maximumX)
    }

    private func settingsPopoverArrowLeading(anchorFrame: CGRect, panelX: CGFloat) -> CGFloat {
        let arrowWidth: CGFloat = 22
        let minimumLeading: CGFloat = 12
        let maximumLeading = DashboardLayout.settingsPanelWidth - arrowWidth - minimumLeading
        return min(max(anchorFrame.midX - panelX - arrowWidth / 2, minimumLeading), maximumLeading)
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
                        .frame(height: 27)
                        .foregroundStyle(appState.language == language ? Branding.accentBlueDark : Branding.inkMuted)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
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
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Branding.controlSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Branding.controlStroke, lineWidth: 1)
        )
        .animation(settingsPopoverAnimation, value: appState.language)
    }

    private var recommendationStrategyControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text.string(.recommendationStrategy))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Branding.inkMuted)
                .padding(.leading, 2)

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
                            .frame(height: 27)
                            .foregroundStyle(appState.recommendationStrategy == strategy ? Branding.accentBlueDark : Branding.inkMuted)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Branding.controlSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Branding.controlStroke, lineWidth: 1)
            )
            .animation(settingsPopoverAnimation, value: appState.recommendationStrategy)
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Branding.inkMuted)
                .padding(.leading, 2)

            VStack(spacing: 4) {
                content()
            }
        }
    }

    private func settingsToggleRow(title: String, iconName: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                settingsRowIcon(iconName)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Branding.inkStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)

                Spacer(minLength: 8)

                Toggle("", isOn: .constant(isOn.wrappedValue))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .allowsHitTesting(false)
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 32)
            .background(settingsRowBackground)
        }
        .buttonStyle(.quotaInteractive())
        .help(title)
        .accessibilityLabel(title)
        .animation(settingsPopoverAnimation, value: isOn.wrappedValue)
    }

    private func settingsActionRow(
        title: String,
        iconName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                settingsRowIcon(iconName)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isEnabled ? Branding.inkStrong : Branding.inkSubtle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isEnabled ? Branding.inkSubtle : Branding.inkSubtle.opacity(0.48))
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .frame(height: 32)
            .background(settingsRowBackground)
            .opacity(isEnabled ? 1 : 0.68)
        }
        .buttonStyle(.quotaInteractive(isEnabled: isEnabled))
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private func settingsRowIcon(_ iconName: String) -> some View {
        Image(systemName: iconName)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Branding.inkMuted)
            .frame(width: 15)
    }

    private var settingsRowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Branding.controlSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Branding.controlStroke, lineWidth: 1)
            )
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

    private var statusBarQuotaTextBinding: Binding<Bool> {
        Binding {
            appState.isStatusBarQuotaTextEnabled
        } set: { enabled in
            appState.setStatusBarQuotaTextEnabled(enabled)
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
        setSettingsMenuPresented(false)
    }

    private var shouldShowUpdateNotice: Bool {
        if case .idle = appState.updateBannerState {
            return false
        }
        return true
    }

    private var updateNoticeBar: some View {
        Button {
            appState.installAvailableUpdateFromDashboard()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: updateNoticeIconName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 16)

                Text(updateNoticeTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .monospacedDigit()

                Spacer(minLength: 8)

                if let action = updateNoticeActionLabel {
                    Text(action)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 23)
                        .foregroundStyle(Branding.primaryActionText)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Branding.accentBlue)
                        )
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, updateNoticeActionLabel == nil ? 12 : 6)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .foregroundStyle(updateNoticeTint)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(updateNoticeBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(updateNoticeTint.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.quotaInteractive(isEnabled: isUpdateNoticeEnabled))
        .disabled(!isUpdateNoticeEnabled)
        .help(updateNoticeTitle)
        .accessibilityLabel(updateNoticeTitle)
        .opacity(isUpdateNoticeEnabled ? 1 : 0.94)
    }

    private var isUpdateNoticeEnabled: Bool {
        if case .available = appState.updateBannerState {
            return true
        }
        return false
    }

    private var updateNoticeIconName: String {
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

    private var updateNoticeTitle: String {
        switch appState.updateBannerState {
        case .available(let version):
            switch appState.language {
            case .english:
                return "New version \(version) available"
            case .simplifiedChinese:
                return "新版本 \(version) 可用"
            case .traditionalChinese:
                return "新版本 \(version) 可用"
            }
        case .checking:
            switch appState.language {
            case .english:
                return "Checking..."
            case .simplifiedChinese:
                return "检查中..."
            case .traditionalChinese:
                return "檢查中..."
            }
        case .downloading(let progress):
            if let progress {
                let percent = Int((progress * 100).rounded())
                switch appState.language {
                case .english:
                    return "Downloading \(percent)%"
                case .simplifiedChinese:
                    return "下载 \(percent)%"
                case .traditionalChinese:
                    return "下載 \(percent)%"
                }
            }
            switch appState.language {
            case .english:
                return "Downloading..."
            case .simplifiedChinese:
                return "下载中..."
            case .traditionalChinese:
                return "下載中..."
            }
        case .installing:
            switch appState.language {
            case .english:
                return "Installing..."
            case .simplifiedChinese:
                return "安装中..."
            case .traditionalChinese:
                return "安裝中..."
            }
        case .idle:
            return ""
        }
    }

    private var updateNoticeActionLabel: String? {
        guard case .available = appState.updateBannerState else { return nil }
        switch appState.language {
        case .english:
            return "Update"
        case .simplifiedChinese:
            return "更新"
        case .traditionalChinese:
            return "更新"
        }
    }

    private var updateNoticeTint: Color {
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

    private var updateNoticeBackground: Color {
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

    private var currentFilterTitle: String {
        accountFilter == .all
            ? text.accountFilterAll(count: toolAccounts.count)
            : text.accountFilterAvailable(count: availableAccountCount)
    }

    private func footerFilterOption(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Branding.inkStrong)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Branding.accentBlueDark)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Branding.menuItemSelectedSurface : Color.clear)
            )
        }
        .buttonStyle(.quotaInteractive())
        .help(title)
        .accessibilityLabel(title)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 58)
    }

    private var filteredEmptyState: some View {
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

private enum AccountListScrollTarget: Hashable {
    case top
}

private struct SettingsButtonAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct PopoverArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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

    private func rotationDegrees(at date: Date) -> Double {
        let duration = 0.85
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration
        return progress * 360
    }
}

private struct ScrollIndicatorHider: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = ScrollIndicatorHidingView()
        view.configureWhenReady()
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? ScrollIndicatorHidingView)?.configureWhenReady()
    }

    private final class ScrollIndicatorHidingView: NSView {
        private weak var configuredScrollView: NSScrollView?
        private var isConfigureScheduled = false

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureWhenReady()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWhenReady()
        }

        override func layout() {
            super.layout()
            configureWhenReady()
        }

        func configureWhenReady() {
            guard !isConfigureScheduled else { return }
            isConfigureScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.configureNearestScrollView()
            }
        }

        private func configureNearestScrollView() {
            isConfigureScheduled = false
            guard let scrollView = enclosingScrollView ?? configuredScrollView ?? findNearestScrollView() else { return }
            configure(scrollView)
            configuredScrollView = scrollView
        }

        private func configure(_ scrollView: NSScrollView) {
            scrollView.scrollerStyle = .overlay
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.verticalScroller?.alphaValue = 0
            scrollView.horizontalScroller?.alphaValue = 0
            scrollView.verticalScroller?.isHidden = true
            scrollView.horizontalScroller?.isHidden = true
            scrollView.verticalScroller = nil
            scrollView.horizontalScroller = nil
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.borderType = .noBorder
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
            hideScrollerSubviews(in: scrollView)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func findNearestScrollView() -> NSScrollView? {
            var view: NSView? = self
            while let current = view {
                if let scrollView = current as? NSScrollView {
                    return scrollView
                }
                if let scrollView = current.superview as? NSScrollView {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }

        private func hideScrollerSubviews(in view: NSView) {
            for subview in view.subviews {
                if let scroller = subview as? NSScroller {
                    scroller.alphaValue = 0
                    scroller.isHidden = true
                }
                hideScrollerSubviews(in: subview)
            }
        }
    }
}
