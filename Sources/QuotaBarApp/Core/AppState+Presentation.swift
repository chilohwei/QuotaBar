import Foundation

extension AppState {
    func refreshSelectedTool() {
        let tool = selectedTool
        primeRefreshState(for: accounts(for: tool))
        Task {
            await syncInstalledCurrentAccount(for: tool)
            let targetAccounts = accounts(for: tool)
            primeRefreshState(for: targetAccounts)
            await refreshAccounts(targetAccounts, intent: .manual)
        }
    }

    func prepareSelectedToolForDashboardPresentation() async {
        let tool = selectedTool
        await syncInstalledCurrentAccount(for: tool)
        guard isRefreshOnOpenEnabled else { return }

        let targetAccounts = accounts(for: tool)
        guard !targetAccounts.isEmpty else { return }
        // `.dashboardOpen` carries its own, much shorter provider-cache floor, so this is a real
        // fetch rather than a cache read — opening the panel is when the numbers have to be live.
        // The app-level gate below still skips accounts refreshed seconds ago (rapid open/close).
        guard shouldRefreshAccounts(
            targetAccounts,
            freshnessInterval: dashboardOpenRefreshFreshnessInterval,
            intent: .dashboardOpen
        ) else { return }

        primeRefreshState(for: targetAccounts)
        await refreshAccounts(targetAccounts, intent: .dashboardOpen)
    }

    func handleAppBecameActive() {
        refreshEventMonitor?.notifyAppForegrounded()
    }

    func handleSystemDidWake() {
        refreshEventMonitor?.notifySystemDidWake()
    }

    func setDashboardVisible(_ visible: Bool) {
        guard isDashboardVisible != visible else { return }
        isDashboardVisible = visible

        if visible {
            startDashboardRefreshLoop()
        } else {
            dashboardRefreshTask?.cancel()
            dashboardRefreshTask = nil
        }
    }

    func setDashboardVisibleAccountIDs(_ ids: [UUID]) {
        dashboardVisibleAccountIDs = ids
    }

    func refreshAccount(_ account: Account) {
        primeRefreshState(for: [account])
        Task {
            await syncInstalledCurrentAccount(for: account.tool)
            let target = accounts.first(where: { $0.id == account.id }) ?? account
            primeRefreshState(for: [target])
            await refreshQuota(for: target, intent: .manual)
        }
    }

    func selectTool(_ tool: ToolKind) {
        guard supportedTools.contains(tool) else { return }
        selectedTool = tool
        let targetAccounts = accounts(for: tool)
        let shouldRefresh = shouldRefreshForForegroundDisplay(targetAccounts)
        if shouldRefresh {
            primeRefreshState(for: targetAccounts)
        }
        Task {
            await syncInstalledCurrentAccount(for: tool)
            let targetAccounts = accounts(for: tool)
            guard shouldRefresh || shouldRefreshForForegroundDisplay(targetAccounts) else { return }
            primeRefreshState(for: targetAccounts)
            await refreshAccounts(targetAccounts, intent: .visible)
        }
    }

    func setLanguage(_ nextLanguage: AppLanguage) {
        language = nextLanguage
        nextLanguage.persist()
    }

    var text: AppText {
        AppText(language: language)
    }

    func registerUpdateActions(
        checkForUpdates: @escaping () -> Void,
        installAvailableUpdate: @escaping () -> Void,
        ignoreAvailableUpdate: @escaping () -> Void
    ) {
        hostActions.checkForUpdates = checkForUpdates
        hostActions.installAvailableUpdate = installAvailableUpdate
        hostActions.ignoreAvailableUpdate = ignoreAvailableUpdate
    }

    func checkForUpdatesFromDashboard() {
        hostActions.checkForUpdates?()
    }

    func installAvailableUpdateFromDashboard() {
        hostActions.installAvailableUpdate?()
    }

    func ignoreAvailableUpdateFromDashboard() {
        hostActions.ignoreAvailableUpdate?()
    }

    func registerLaunchAtLoginActions(
        isEnabled: @escaping () -> Bool,
        setEnabled: @escaping (Bool) -> Void
    ) {
        hostActions.isLaunchAtLoginEnabled = isEnabled
        hostActions.setLaunchAtLoginEnabled = setEnabled
        refreshLaunchAtLoginState()
    }

    func refreshLaunchAtLoginState() {
        isLaunchAtLoginEnabled = hostActions.isLaunchAtLoginEnabled?() ?? false
    }

    func setLaunchAtLoginEnabledFromDashboard(_ enabled: Bool) {
        hostActions.setLaunchAtLoginEnabled?(enabled)
    }

    func setRefreshOnOpenEnabled(_ enabled: Bool) {
        guard isRefreshOnOpenEnabled != enabled else { return }
        isRefreshOnOpenEnabled = enabled
        AppPreferencesStore.setRefreshOnOpenEnabled(enabled)
    }

    func setQuotaNotificationsEnabled(_ enabled: Bool) {
        guard isQuotaNotificationsEnabled != enabled else { return }
        isQuotaNotificationsEnabled = enabled
        AppPreferencesStore.setQuotaNotificationsEnabled(enabled)
    }

    func setQuotaNotificationThreshold(_ threshold: Double) {
        guard quotaNotificationThreshold != threshold else { return }
        quotaNotificationThreshold = threshold
        AppPreferencesStore.setQuotaNotificationThreshold(threshold)
    }

    func registerDashboardCloseAction(_ action: @escaping () -> Void) {
        hostActions.closeDashboard = action
    }

    func closeDashboard() {
        hostActions.closeDashboard?()
    }

    func registerToolRestartAction(_ action: @escaping (ToolKind) -> Void) {
        hostActions.restartTool = action
    }

    func registerRestartPromptPresenter(_ action: @escaping (ToolKind, String) -> Void) {
        hostActions.presentRestartPrompt = action
    }

    var canRestartTool: Bool {
        // Only Cursor's restart is offered from the notice bar — Codex prompts via a dialog
        // (see activateAccount) and Claude Code remains a terminal session only the user
        // can restart.
        restartRequiredTool == .cursor && hostActions.restartTool != nil
    }

    func restartRequiredToolNow() {
        guard let tool = restartRequiredTool, canRestartTool else { return }
        restartToolNow(tool)
        dismissRestartRequiredMessage()
    }

    /// Direct restart for dialog-driven prompts, which carry their own tool context instead
    /// of going through the notice-bar state.
    func restartToolNow(_ tool: ToolKind) {
        hostActions.restartTool?(tool)
        scheduleActiveSelectionReassertion(for: tool)
    }

    /// A restart is exactly when the tool's credential file is most likely to be rewritten behind
    /// QuotaBar's back: a terminal `codex` flushes its in-memory auth on SIGTERM, and a relaunched
    /// host app (the ChatGPT desktop app, an IDE extension) restores the account *it* was signed
    /// into. Either one silently reverts the switch the user just made, so the restarted tool comes
    /// back on the previous account. Watch the file across the restart and put the selection back.
    func setRecommendationStrategy(_ strategy: AccountRecommendationStrategy) {
        guard recommendationStrategy != strategy else { return }
        recommendationStrategy = strategy
        AppPreferencesStore.setRecommendationStrategy(strategy)
    }

    func isToolVisibleInMenuBar(_ tool: ToolKind) -> Bool {
        menuBarVisibleTools.contains(tool)
    }

    func setToolVisibleInMenuBar(_ tool: ToolKind, _ visible: Bool) {
        if visible {
            menuBarVisibleTools.insert(tool)
        } else {
            menuBarVisibleTools.remove(tool)
        }
        AppPreferencesStore.setMenuBarVisibleTools(menuBarVisibleTools)
    }

}
