import AppKit
import SwiftUI

struct DashboardPanelBackground: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Rectangle()
                .fill(Branding.pageBackground.opacity(0.84))
        }
    }
}

enum DashboardLayout {
    static let contentWidth: CGFloat = 440
    static let panelWidth: CGFloat = contentWidth
    static let fixedPanelHeight: CGFloat = 580
    static let minimumUsablePanelHeight: CGFloat = 360
    static let accountCardHeight: CGFloat = 144
    static let accountCardSpacing: CGFloat = 10
    static let maxVisibleAccountCards = 3
    static let headerHeight: CGFloat = 60
    static let stackSpacing: CGFloat = 8
    static let headerListSpacing: CGFloat = 10
    static let listFooterSpacing: CGFloat = 6
    static let bottomReserve: CGFloat = 8
    static let updateNoticeHeight: CGFloat = 36
    static let panelCornerRadius: CGFloat = 10

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
    @ObservedObject var loginProgress = LoginFlowProgress.shared
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var accountFilter: AccountFilter = .all
    @State var refreshCycleID: Int = 0
    @State var isFilterMenuPresented: Bool = false
    @State var isToolMenuPresented: Bool = false
    @State var isSettingsMenuPresented: Bool = false
    @State var frozenAccountOrderByTool: [ToolKind: [UUID]] = [:]
    @State var lastVisibleAccountOrderByTool: [ToolKind: [UUID]] = [:]
    @State private var highlightedAccountID: UUID?
    @State private var highlightClearTask: Task<Void, Never>?
    @State private var keyboardSelectedAccountID: UUID?

    var text: AppText { appState.text }

    var toolAccounts: [Account] {
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

    var visibleAccountIDs: [UUID] {
        visibleAccounts.map(\.id)
    }

    private var preferredPanelHeight: CGFloat {
        DashboardLayout.preferredPanelHeight
    }

    private var accountListHeight: CGFloat {
        let noticeReserve = topNotice != nil
            ? DashboardLayout.updateNoticeHeight + DashboardLayout.stackSpacing
            : 0
        let panelCompression = max(0, DashboardLayout.fixedPanelHeight - preferredPanelHeight)
        let dynamicHeight = DashboardLayout.accountListHeight - noticeReserve - panelCompression
        return max(dynamicHeight, DashboardLayout.accountCardHeight)
    }

    var isRefreshingSelectedTool: Bool {
        toolAccounts.contains { account in
            appState.loadStateByAccount[account.id] == .refreshing
                || appState.loadStateByAccount[account.id] == .loadingInitial
        }
    }

    var availableAccountCount: Int {
        AccountListPresenter.availableAccountCount(
            accounts: toolAccounts,
            quotaByAccount: appState.quotaByAccount
        )
    }

    var activeAccountName: String? {
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
        .background(DashboardPanelBackground())
        .foregroundStyle(Branding.ink)
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
            if let selectedID = keyboardSelectedAccountID, !ids.contains(selectedID) {
                keyboardSelectedAccountID = nil
            }
            guard !isRefreshingSelectedTool else { return }
            rememberVisibleOrderForSelectedTool(ids)
        }
        .onChange(of: appState.selectedTool) { _ in
            isToolMenuPresented = false
            keyboardSelectedAccountID = nil
            appState.setDashboardVisibleAccountIDs(visibleAccountIDs)
            rememberVisibleOrderForSelectedTool(visibleAccountIDs)
        }
        .onAppear {
            appState.setDashboardVisibleAccountIDs(visibleAccountIDs)
            rememberVisibleOrderForSelectedTool(visibleAccountIDs)
        }
        .onDisappear {
            appState.setDashboardVisibleAccountIDs([])
            keyboardSelectedAccountID = nil
            highlightClearTask?.cancel()
            highlightClearTask = nil
            highlightedAccountID = nil
        }
    }

    func freezeCurrentAccountOrder() {
        let ids = visibleAccountIDs
        frozenAccountOrderByTool[appState.selectedTool] = ids
        rememberVisibleOrderForSelectedTool(ids)
    }

    var effectiveFrozenOrder: [UUID]? {
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

    func preferredFrozenOrderForSelectedTool() -> [UUID] {
        let tool = appState.selectedTool
        if let remembered = lastVisibleAccountOrderByTool[tool], !remembered.isEmpty {
            return activeFirstOrder(remembered)
        }
        return activeFirstOrder(visibleAccountIDs)
    }

    func rememberVisibleOrderForSelectedTool(_ ids: [UUID]) {
        lastVisibleAccountOrderByTool[appState.selectedTool] = activeFirstOrder(ids)
    }

    func activeFirstOrder(_ ids: [UUID]) -> [UUID] {
        guard let activeID = appState.activeAccountByTool[appState.selectedTool],
              ids.contains(activeID) else {
            return ids
        }
        return [activeID] + ids.filter { $0 != activeID }
    }

    func accountLoadState(_ account: Account) -> AccountLoadState {
        appState.loadStateByAccount[account.id] ?? .idle
    }

    func isAccountRefreshing(_ account: Account) -> Bool {
        let state = accountLoadState(account)
        return state == .refreshing || state == .loadingInitial
    }

    func setSettingsMenuPresented(_ isPresented: Bool) {
        withAnimation(settingsPopoverAnimation) {
            isSettingsMenuPresented = isPresented
        }
    }

    var settingsPopoverAnimation: Animation? {
        reduceMotion ? nil : .quotaFluid
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
                if let notice = topNotice {
                    Spacer()
                        .frame(height: DashboardLayout.stackSpacing)
                    topNoticeBar(notice)
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
        .background(keyboardShortcutButtons)
    }

    @ViewBuilder
    var accountList: some View {
        let accounts = visibleAccounts
        let listHeight = accountListHeight

        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    if toolAccounts.isEmpty {
                        emptyState
                    } else if accounts.isEmpty {
                        filteredEmptyState
                    } else {
                        LazyVStack(spacing: DashboardLayout.accountCardSpacing) {
                            ForEach(accounts) { account in
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
                                    errorRequiresUserAction: appState.errorRequiresUserActionByAccount[account.id] == true,
                                    canActivate: true,
                                    isHighlighted: highlightedAccountID == account.id,
                                    isKeyboardFocused: keyboardSelectedAccountID == account.id,
                                    refreshCycleID: refreshCycleID,
                                    onActivate: { appState.activateAccount(account) },
                                    onRefresh: { appState.refreshAccount(account) },
                                    onDelete: { appState.deleteAccount(account) }
                                )
                                .id(account.id)
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
            .overlay(alignment: .bottom) {
                if accounts.count > DashboardLayout.maxVisibleAccountCards {
                    LinearGradient(
                        colors: [Branding.pageBackground.opacity(0), Branding.pageBackground.opacity(0.88)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 20)
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 18)
            .onChange(of: refreshCycleID) { _ in
                scrollAccountListToTop(using: scrollProxy)
            }
            .onChange(of: appState.lastAddedAccountID) { addedID in
                guard let addedID else { return }
                landOnAccount(addedID, using: scrollProxy)
            }
            .onChange(of: keyboardSelectedAccountID) { selectedID in
                guard let selectedID else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    scrollProxy.scrollTo(selectedID, anchor: nil)
                }
            }
        }
    }

    private func landOnAccount(_ accountID: UUID, using scrollProxy: ScrollViewProxy) {
        accountFilter = .all
        highlightClearTask?.cancel()
        highlightedAccountID = accountID
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                scrollProxy.scrollTo(accountID, anchor: .center)
            }
        }
        highlightClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) {
                highlightedAccountID = nil
            }
        }
    }

    // Hidden buttons carry the panel's keyboard shortcuts: Esc dismisses the
    // topmost layer, ⌘R refreshes, arrows move card focus, Return activates.
    private var keyboardShortcutButtons: some View {
        Group {
            Button(action: handleEscapeKey) { EmptyView() }
                .keyboardShortcut(.cancelAction)

            Button(action: refreshFromKeyboard) { EmptyView() }
                .keyboardShortcut("r", modifiers: .command)

            Button(action: { moveKeyboardSelection(by: 1) }) { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: [])

            Button(action: { moveKeyboardSelection(by: -1) }) { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: [])

            Button(action: activateKeyboardSelection) { EmptyView() }
                .keyboardShortcut(.return, modifiers: [])
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func handleEscapeKey() {
        if isSettingsMenuPresented {
            setSettingsMenuPresented(false)
            return
        }
        if isToolMenuPresented || isFilterMenuPresented {
            isToolMenuPresented = false
            isFilterMenuPresented = false
            return
        }
        if keyboardSelectedAccountID != nil {
            keyboardSelectedAccountID = nil
            return
        }
        appState.closeDashboard()
    }

    private func refreshFromKeyboard() {
        guard !isRefreshingSelectedTool, !toolAccounts.isEmpty else { return }
        freezeCurrentAccountOrder()
        refreshCycleID += 1
        appState.refreshSelectedTool()
    }

    private func moveKeyboardSelection(by delta: Int) {
        let ids = visibleAccountIDs
        guard !ids.isEmpty else { return }
        guard let current = keyboardSelectedAccountID,
              let index = ids.firstIndex(of: current) else {
            keyboardSelectedAccountID = delta > 0 ? ids.first : ids.last
            return
        }
        let next = min(max(index + delta, 0), ids.count - 1)
        keyboardSelectedAccountID = ids[next]
    }

    private func activateKeyboardSelection() {
        guard let selectedID = keyboardSelectedAccountID,
              let account = visibleAccounts.first(where: { $0.id == selectedID }),
              appState.activeAccountByTool[appState.selectedTool] != account.id else {
            return
        }
        appState.activateAccount(account)
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

    private var settingsCover: some View {
        DashboardSettingsView(
            appState: appState,
            preferredPanelHeight: preferredPanelHeight,
            settingsPopoverAnimation: settingsPopoverAnimation,
            onClose: { setSettingsMenuPresented(false) }
        )
        .transition(settingsCoverTransition)
        .animation(settingsPopoverAnimation, value: isSettingsMenuPresented)
    }

    private var settingsCoverTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .move(edge: .trailing).combined(with: .opacity)
    }

}

private enum AccountListScrollTarget: Hashable {
    case top
}

