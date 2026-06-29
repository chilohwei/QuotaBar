import AppKit
import SwiftUI

enum DashboardLayout {
    static let contentWidth: CGFloat = 430
    static let sidebarWidth: CGFloat = 54
    static let panelWidth: CGFloat = contentWidth
    static let fixedPanelHeight: CGFloat = 620
    static let minimumUsablePanelHeight: CGFloat = 360
    static let accountCardHeight: CGFloat = 144
    static let accountCardSpacing: CGFloat = 10
    static let maxVisibleAccountCards = 3
    static let headerHeight: CGFloat = 64
    static let stackSpacing: CGFloat = 10
    static let headerListSpacing: CGFloat = 12
    static let listFooterSpacing: CGFloat = 8
    static let bottomReserve: CGFloat = 12
    static let updateNoticeHeight: CGFloat = 36

    static var maxAccountListHeight: CGFloat {
        CGFloat(maxVisibleAccountCards) * accountCardHeight
            + CGFloat(maxVisibleAccountCards - 1) * accountCardSpacing
    }

    static var panelSize: NSSize {
        NSSize(width: panelWidth, height: preferredPanelHeight)
    }

    static var preferredPanelHeight: CGFloat {
        let availableHeight = (NSScreen.main?.visibleFrame.height ?? fixedPanelHeight) - 28
        guard availableHeight > 0 else { return fixedPanelHeight }
        return min(fixedPanelHeight, max(minimumUsablePanelHeight, availableHeight))
    }

    static let accountListHeight = maxAccountListHeight
}

struct DashboardView: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var accountFilter: AccountFilter = .all
    @State private var refreshCycleID: Int = 0
    @State private var isFilterMenuPresented: Bool = false
    @State private var isToolMenuPresented: Bool = false
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
        DashboardLayout.preferredPanelHeight
    }

    private var accountListHeight: CGFloat {
        let updateNoticeReserve = shouldShowUpdateNotice
            ? DashboardLayout.updateNoticeHeight + DashboardLayout.stackSpacing
            : 0
        let panelCompression = max(0, DashboardLayout.fixedPanelHeight - preferredPanelHeight)
        let dynamicHeight = DashboardLayout.accountListHeight - updateNoticeReserve - panelCompression
        return max(dynamicHeight, DashboardLayout.accountCardHeight)
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
        rightPane
        .frame(width: DashboardLayout.panelWidth, height: preferredPanelHeight, alignment: .top)
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
            appState.setDashboardVisibleAccountIDs(ids)
            guard !isRefreshingSelectedTool else { return }
            rememberVisibleOrderForSelectedTool(ids)
        }
        .onChange(of: appState.selectedTool) { _ in
            isToolMenuPresented = false
            appState.setDashboardVisibleAccountIDs(visibleAccountIDs)
            rememberVisibleOrderForSelectedTool(visibleAccountIDs)
        }
        .onAppear {
            appState.setDashboardVisibleAccountIDs(visibleAccountIDs)
            rememberVisibleOrderForSelectedTool(visibleAccountIDs)
        }
        .onDisappear {
            appState.setDashboardVisibleAccountIDs([])
        }
    }

    private var rightPane: some View {
        ZStack(alignment: .topLeading) {
            mainContent

            if isSettingsMenuPresented {
                settingsCover
                    .zIndex(2)
            }
        }
        .frame(width: DashboardLayout.contentWidth, height: preferredPanelHeight, alignment: .top)
        .clipped()
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if shouldShowUpdateNotice {
                    Spacer()
                        .frame(height: DashboardLayout.stackSpacing)
                    updateNoticeBar
                        .padding(.horizontal, 18)
                }
                Spacer()
                    .frame(height: DashboardLayout.headerListSpacing)
                accountList
            }
            .padding(.top, 8)
            Spacer(minLength: DashboardLayout.listFooterSpacing)
            footerBar
        }
        .frame(width: DashboardLayout.contentWidth, height: preferredPanelHeight, alignment: .top)
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
        reduceMotion ? nil : .quotaFluid
    }

    private var header: some View {
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

    private var headerTitle: String {
        text.usageHeadline
    }

    private var toolPickerButton: some View {
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
                Capsule(style: .continuous)
                    .fill(Branding.controlSurface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isToolMenuPresented ? Branding.accentBlue.opacity(0.35) : Branding.separatorDot,
                        lineWidth: isToolMenuPresented ? 1 : 0.75
                    )
            )
            .shadow(color: Branding.shadowPopover.opacity(0.6), radius: 2.5, y: 1)
            .contentShape(Capsule(style: .continuous))
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

    private func toolPickerOption(_ tool: ToolKind) -> some View {
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

    private func toolPickerLogoSize(for tool: ToolKind) -> CGFloat {
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
    private var headerStatus: some View {
        HStack(spacing: 6) {
            Text(text.string(.current))
                .font(.system(size: 11.5, weight: .light))
                .foregroundStyle(Branding.inkSubtle)

            Text(activeAccountName ?? "--")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Branding.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

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
                    Capsule(style: .continuous)
                        .fill(appState.isAddingAccount ? Branding.warningSoft : Branding.accentBlueSoft)
                )
                .overlay(
                    Capsule(style: .continuous)
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(headerRefreshButtonTint(isEnabled: isEnabled, isBusy: isBusy))
                .opacity(isEnabled || isBusy ? 1 : 0.58)
                .frame(width: 32, height: 30)
                .background(
                    Capsule(style: .continuous)
                        .fill(isBusy ? Branding.accentBlueSoft : Branding.controlSurface)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            isBusy ? Branding.accentBlue.opacity(0.12) : Branding.controlStroke,
                            lineWidth: 0.75
                        )
                )
                .contentShape(Capsule(style: .continuous))
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

    @ViewBuilder
    private var accountList: some View {
        let accounts = visibleAccounts
        let listHeight = accountListHeight

        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
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
            .clipped()
            .frame(height: listHeight)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
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
        HStack(alignment: .center, spacing: 8) {
            Button {
                isFilterMenuPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(text.string(.show))
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(Branding.inkSubtle.opacity(0.78))
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
                        .foregroundStyle(Branding.inkSubtle.opacity(0.56))
                        .rotationEffect(.degrees(isFilterMenuPresented ? 180 : 0))
                }
                .padding(.leading, 9)
                .padding(.trailing, 8)
                .frame(height: 26)
                .background(
                    Capsule(style: .continuous)
                        .fill(Branding.controlSurface)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            isFilterMenuPresented ? Branding.accentBlue.opacity(0.10) : Branding.controlStroke.opacity(0.45),
                            lineWidth: 0.75
                        )
                )
                .contentShape(Capsule(style: .continuous))
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
                .foregroundStyle(Branding.inkSubtle.opacity(0.68))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.quotaInteractive())
            .help(text.string(.quit))
            .accessibilityLabel(text.string(.quit))
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .background(Branding.pageBackground)
    }

    private var settingsCover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(text.string(.settings))
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(Branding.inkStrong)
                    .lineLimit(1)

                Spacer(minLength: 10)

                Button {
                    setSettingsMenuPresented(false)
                } label: {
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

            Spacer()
                .frame(height: 6)

            ScrollView(.vertical, showsIndicators: true) {
                settingsPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .clipped()

            Spacer(minLength: DashboardLayout.bottomReserve)
        }
        .padding(.top, 8)
        .padding(.horizontal, 18)
        .frame(width: DashboardLayout.contentWidth, height: preferredPanelHeight, alignment: .top)
        .background(Branding.pageBackground)
        .transition(settingsCoverTransition)
        .animation(settingsPopoverAnimation, value: isSettingsMenuPresented)
    }

    private var settingsCoverTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .move(edge: .trailing).combined(with: .opacity)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSection(title: text.string(.language)) {
                languageSegmentedControl
            }

            settingsSection(title: text.string(.settingsRecommendation)) {
                recommendationStrategyControl
            }

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

                settingsToggleRow(
                    title: text.string(.localToolModification),
                    subtitle: text.localToolModificationDescription,
                    iconName: "lock.open",
                    isOn: localToolModificationBinding
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

    private var recommendationStrategyControl: some View {
        VStack(alignment: .leading, spacing: 7) {
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

    private var localToolModificationBinding: Binding<Bool> {
        Binding {
            appState.isLocalToolModificationEnabled
        } set: { enabled in
            appState.setLocalToolModificationEnabled(enabled)
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
                RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
                    .fill(updateNoticeBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Branding.radiusControl, style: .continuous)
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

    private var currentFilterLabel: String {
        filterTitle(accountFilter)
    }

    private var currentFilterCount: Int {
        filterCount(accountFilter)
    }

    private func filterTitle(_ filter: AccountFilter) -> String {
        switch filter {
        case .all:
            return text.accountFilterAllTitle
        case .available:
            return text.accountFilterAvailableTitle
        }
    }

    private func filterCount(_ filter: AccountFilter) -> Int {
        switch filter {
        case .all:
            return toolAccounts.count
        case .available:
            return availableAccountCount
        }
    }

    private func filterAccessibilityTitle(_ filter: AccountFilter) -> String {
        switch filter {
        case .all:
            return text.accountFilterAll(count: toolAccounts.count)
        case .available:
            return text.accountFilterAvailable(count: availableAccountCount)
        }
    }

    private func footerFilterOption(filter: AccountFilter, action: @escaping () -> Void) -> some View {
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

    private var emptyState: some View {
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
                    Capsule(style: .continuous)
                        .fill(appState.isAddingAccount ? Branding.warningSoft : Branding.accentBlueSoft)
                )
                .overlay(
                    Capsule(style: .continuous)
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
