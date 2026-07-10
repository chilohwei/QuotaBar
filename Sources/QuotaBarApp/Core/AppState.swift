import CryptoKit
import Foundation

enum AddAccountPhase: Equatable {
    case importingLocal
    case waitingBrowserAuthorization
    case fetchingUsage
}

struct TransientNotice: Equatable {
    enum Action: Equatable {
        case activateAccount(UUID)
        case undoDeletion(UUID)
    }

    let message: String
    var actionTitle: String?
    var action: Action?
}

@MainActor
final class AppState: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var activeAccountByTool: [ToolKind: UUID] = [:]
    @Published var selectedTool: ToolKind = .codex
    @Published var quotaByAccount: [UUID: QuotaSnapshot] = [:]
    @Published var errorByAccount: [UUID: String] = [:]
    @Published var errorRequiresUserActionByAccount: [UUID: Bool] = [:]
    @Published var loadStateByAccount: [UUID: AccountLoadState] = [:]
    @Published var isAddingAccount = false
    @Published var addAccountPhase: AddAccountPhase?
    @Published var transientNotice: TransientNotice?
    @Published var lastAddedAccountID: UUID?
    @Published var language: AppLanguage = .stored
    @Published var restartRequiredMessage: String?
    @Published var restartRequiredTool: ToolKind?
    @Published var addAccountErrorMessage: String?
    @Published var updateBannerState: AppUpdateBannerState = .idle
    @Published var isLaunchAtLoginEnabled = false
    @Published var isRefreshOnOpenEnabled: Bool = AppPreferencesStore.refreshOnOpenEnabled
    @Published var isQuotaNotificationsEnabled: Bool = AppPreferencesStore.quotaNotificationsEnabled
    @Published var quotaNotificationThreshold: Double = AppPreferencesStore.quotaNotificationThreshold
    @Published var recommendationStrategy: AccountRecommendationStrategy = AppPreferencesStore.recommendationStrategy
    @Published var menuBarVisibleTools: Set<ToolKind> = AppPreferencesStore.menuBarVisibleTools

    private let accountStore = AccountStore()
    private let secretStore = SecretStoreService()
    let quotaCacheStore = QuotaSnapshotCacheStore()
    private let providerRegistry = ProviderRegistry()
    let refreshBackoffPolicy = RefreshBackoffPolicy()
    let refreshIntervalPolicy = RefreshIntervalPolicy()
    let notificationService = QuotaNotificationService()
    private var checkForUpdatesAction: (() -> Void)?
    private var installAvailableUpdateAction: (() -> Void)?
    private var ignoreAvailableUpdateAction: (() -> Void)?
    private var launchAtLoginEnabledProvider: (() -> Bool)?
    private var setLaunchAtLoginEnabledAction: ((Bool) -> Void)?
    private var closeDashboardAction: (() -> Void)?
    private var toolRestartAction: ((ToolKind) -> Void)?
    private var restartPromptPresenter: ((ToolKind, String) -> Void)?

    var refreshTask: Task<Void, Never>?
    var dashboardRefreshTask: Task<Void, Never>?
    private var addAccountTask: Task<Void, Never>?
    private var addAccountOperationID: UUID?
    private var transientNoticeTask: Task<Void, Never>?
    private var pendingDeletion: PendingAccountDeletion?

    private struct PendingAccountDeletion {
        let account: Account
        let snapshot: QuotaSnapshot?
        let loadState: AccountLoadState?
        let wasActive: Bool
        var finalizeTask: Task<Void, Never>?
    }
    var refreshEventMonitor: RefreshEventMonitor?
    var refreshEventTasks: [RefreshEventReason: Task<Void, Never>] = [:]
    var credentialSignatureByTool: [ToolKind: String] = [:]
    var isDashboardVisible = false
    var dashboardVisibleAccountIDs: [UUID] = []
    var refreshingAccountIDs: Set<UUID> = []
    var refreshFailureCountByAccount: [UUID: Int] = [:]
    var refreshBackoffUntilByAccount: [UUID: Date] = [:]
    let maxConcurrentRefreshes = 4
    let autoRefreshJitter = RefreshIntervalPolicy.jitterInterval
    let foregroundRefreshFreshnessInterval: TimeInterval = 30
    let dashboardOpenRefreshFreshnessInterval: TimeInterval = 25
    let dashboardVisibleRefreshInterval: TimeInterval = 30
    var supportedTools: [ToolKind] { providerRegistry.supportedTools }

    var supportedToolsPrioritizingSelectedTool: [ToolKind] {
        guard supportedTools.contains(selectedTool) else { return supportedTools }
        return [selectedTool] + supportedTools.filter { $0 != selectedTool }
    }

    func bootstrap() {
        AppLog.app.info("Bootstrapping app state")
        selectedTool = .codex
        loadPersistedStateForImmediateDisplay()

        Task {
            do {
                let state = try await accountStore.load()
                applyPersistedState(state)
            } catch {
                AppLog.app.error("Failed to load persisted state: \(String(describing: error), privacy: .private)")
                self.accounts = []
                self.activeAccountByTool = [:]
                self.selectedTool = .codex
            }

            loadCachedQuotaSnapshots()
            normalizeActiveSelections()
            let initialSelectedTool = selectedTool
            let initiallySelectedAccounts = accounts(for: initialSelectedTool)
            primeRefreshState(for: initiallySelectedAccounts)
            await refreshAccounts(initiallySelectedAccounts, intent: .visible)

            await syncInstalledCredentialsAtLaunch()
            normalizeActiveSelections()
            await applyActiveSelectionsToInstalledTools()
            await normalizeAccountNamesIfNeeded()

            let selectedAccounts = accounts(for: selectedTool)
            if selectedTool != initialSelectedTool || shouldRefreshForForegroundDisplay(selectedAccounts) {
                primeRefreshState(for: selectedAccounts)
                await refreshAccounts(selectedAccounts, intent: .visible)
            }

            loadCachedQuotaSnapshots()
            startAutoRefreshLoop()
            startRefreshEventMonitor()
            await refreshRemainingAccountsInBackground(excluding: Set(selectedAccounts.map(\.id)))
            AppLog.app.info("App state bootstrap finished")
        }
    }

    func shutdown() {
        finalizePendingDeletionNow()
        refreshTask?.cancel()
        dashboardRefreshTask?.cancel()
        addAccountTask?.cancel()
        transientNoticeTask?.cancel()
        refreshEventTasks.values.forEach { $0.cancel() }
        refreshEventTasks.removeAll()
        refreshEventMonitor?.stop()
        refreshEventMonitor = nil
    }

    func accounts(for tool: ToolKind) -> [Account] {
        guard supportedTools.contains(tool) else { return [] }

        let activeID = activeAccountByTool[tool]
        return accounts
            .filter { $0.tool == tool }
            .sorted { lhs, rhs in
                if lhs.id == activeID { return true }
                if rhs.id == activeID { return false }

                return lhs.createdAt < rhs.createdAt
            }
    }

    func activeAccount(for tool: ToolKind) -> Account? {
        guard let activeID = activeAccountByTool[tool] else { return nil }
        return accounts.first(where: { $0.id == activeID })
    }

    func recommendedAccount(for tool: ToolKind) -> Account? {
        let toolAccounts = accounts(for: tool)
        guard let recommendedID = AccountListPresenter.recommendedAccountID(
            accounts: toolAccounts,
            activeID: activeAccountByTool[tool],
            quotaByAccount: quotaByAccount,
            loadStateByAccount: loadStateByAccount,
            recommendationStrategy: recommendationStrategy
        ) else { return nil }
        return toolAccounts.first { $0.id == recommendedID }
    }

    func quickAddAccount(tool: ToolKind) {
        guard supportedTools.contains(tool) else { return }

        if isAddingAccount {
            cancelAddAccount()
            return
        }

        addAccountTask?.cancel()
        let operationID = UUID()
        addAccountOperationID = operationID
        isAddingAccount = true
        addAccountErrorMessage = nil

        addAccountTask = Task {
            defer {
                if addAccountOperationID == operationID {
                    addAccountTask = nil
                    addAccountOperationID = nil
                    isAddingAccount = false
                    addAccountPhase = nil
                    LoginFlowProgress.shared.end()
                }
            }

            let provider = provider(for: tool)
            do {
                try Task.checkCancellation()
                let quickSecret = try await quickAddSecret(tool: tool, provider: provider)
                try Task.checkCancellation()
                addAccountPhase = .fetchingUsage
                let account = try await addAccount(
                    tool: tool,
                    name: "",
                    secret: quickSecret.secret,
                    makeActive: false,
                    useAsDefaultActive: false,
                    applyToTool: false
                )
                handleAddAccountSuccess(
                    account: account,
                    updatedExistingAccount: quickSecret.matchesExistingAccount,
                    tool: tool
                )
            } catch is CancellationError {
            } catch {
                AppLog.account.error("Add account failed for \(tool.rawValue, privacy: .public): \(String(describing: error), privacy: .private)")
                addAccountErrorMessage = text.addAccountFailedMessage(resolvedErrorMessage(error))
                notifyAddAccountFailureIfDashboardHidden(tool: tool, error: error)
            }
        }
    }

    private struct QuickAddSecretResult {
        let secret: String
        let matchesExistingAccount: Bool
    }

    private func quickAddSecret(tool: ToolKind, provider: any Provider) async throws -> QuickAddSecretResult {
        addAccountPhase = .importingLocal
        if let importedSecret = try? await provider.importCurrentCredentials(),
           !importedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           storedDuplicate(for: tool, provider: provider, secret: importedSecret) == nil {
            return QuickAddSecretResult(secret: importedSecret, matchesExistingAccount: false)
        }

        addAccountPhase = .waitingBrowserAuthorization
        let secret = try await provider.authenticateViaBrowser(allowExistingCredentials: false)
        let matchesExisting = storedDuplicate(for: tool, provider: provider, secret: secret) != nil
        return QuickAddSecretResult(secret: secret, matchesExistingAccount: matchesExisting)
    }

    private func handleAddAccountSuccess(account: Account, updatedExistingAccount: Bool, tool: ToolKind) {
        lastAddedAccountID = account.id
        let notice = updatedExistingAccount
            ? text.duplicateAccountUpdatedNotice(account.name)
            : text.accountAddedNotice(account.name)
        let isAlreadyActive = activeAccountByTool[tool] == account.id
        showTransientNotice(
            notice,
            actionTitle: isAlreadyActive ? nil : text.string(.useAccount),
            action: isAlreadyActive ? nil : .activateAccount(account.id)
        )

        if !isDashboardVisible {
            notificationService.post(
                identifier: "add-account-\(account.id.uuidString)",
                title: text.addAccountSucceededNotificationTitle(tool: tool),
                body: notice
            )
        }
    }

    private func notifyAddAccountFailureIfDashboardHidden(tool: ToolKind, error: Error) {
        guard !isDashboardVisible else { return }
        notificationService.post(
            identifier: "add-account-failed-\(tool.rawValue)",
            title: text.addAccountFailedNotificationTitle(tool: tool),
            body: resolvedErrorMessage(error)
        )
    }

    func showTransientNotice(
        _ message: String,
        actionTitle: String? = nil,
        action: TransientNotice.Action? = nil,
        duration: TimeInterval = 4
    ) {
        transientNoticeTask?.cancel()
        transientNotice = TransientNotice(message: message, actionTitle: actionTitle, action: action)
        transientNoticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            transientNotice = nil
            transientNoticeTask = nil
        }
    }

    func dismissTransientNotice() {
        transientNoticeTask?.cancel()
        transientNoticeTask = nil
        transientNotice = nil
    }

    func performTransientNoticeAction() {
        guard let action = transientNotice?.action else { return }
        dismissTransientNotice()
        switch action {
        case .activateAccount(let accountID):
            guard let account = accounts.first(where: { $0.id == accountID }) else { return }
            activateAccount(account)
        case .undoDeletion(let accountID):
            undoPendingDeletion(accountID: accountID)
        }
    }

    private func storedDuplicate(
        for tool: ToolKind,
        provider: any Provider,
        secret: String
    ) -> Account? {
        let detectedIdentity = provider.accountIdentity(from: secret)
        let detectedIdentityAliases = provider.accountIdentityAliases(from: secret)
        return findDuplicateStoredAccount(
            for: tool,
            detectedIdentities: detectedIdentityAliases.isEmpty
                ? detectedIdentity.map { [$0] } ?? []
                : detectedIdentityAliases
        )
    }

    func cancelAddAccount() {
        guard isAddingAccount else { return }
        addAccountTask?.cancel()
        addAccountTask = nil
        addAccountOperationID = nil
        isAddingAccount = false
        addAccountPhase = nil
    }

    // Deleting hides the account immediately but defers the destructive work (keychain,
    // managed profile, caches) behind a short undo window.
    func deleteAccount(_ account: Account) {
        finalizePendingDeletionNow()

        let wasActive = activeAccountByTool[account.tool] == account.id
        var pending = PendingAccountDeletion(
            account: account,
            snapshot: quotaByAccount[account.id],
            loadState: loadStateByAccount[account.id],
            wasActive: wasActive,
            finalizeTask: nil
        )

        accounts.removeAll { $0.id == account.id }
        quotaByAccount[account.id] = nil
        errorByAccount[account.id] = nil
        errorRequiresUserActionByAccount[account.id] = nil
        loadStateByAccount[account.id] = nil
        if wasActive {
            activeAccountByTool[account.tool] = accounts.first(where: { $0.tool == account.tool })?.id
        }

        pending.finalizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            await finalizeDeletion(accountID: account.id)
        }
        pendingDeletion = pending

        Task { try? await persistState() }

        showTransientNotice(
            text.accountDeletedNotice(account.name),
            actionTitle: text.string(.undo),
            action: .undoDeletion(account.id),
            duration: 7
        )
    }

    func undoPendingDeletion(accountID: UUID) {
        guard let pending = pendingDeletion, pending.account.id == accountID else { return }
        pending.finalizeTask?.cancel()
        pendingDeletion = nil

        accounts.append(pending.account)
        if let snapshot = pending.snapshot {
            quotaByAccount[pending.account.id] = snapshot
        }
        if let loadState = pending.loadState {
            loadStateByAccount[pending.account.id] = loadState
        }
        if pending.wasActive {
            activeAccountByTool[pending.account.tool] = pending.account.id
        }
        Task { try? await persistState() }
    }

    private func finalizeDeletion(accountID: UUID) async {
        guard let pending = pendingDeletion, pending.account.id == accountID else { return }
        pendingDeletion = nil
        await performPhysicalDeletion(pending)
    }

    private func finalizePendingDeletionNow() {
        guard let pending = pendingDeletion else { return }
        pending.finalizeTask?.cancel()
        pendingDeletion = nil
        Task { await performPhysicalDeletion(pending) }
    }

    private func performPhysicalDeletion(_ pending: PendingAccountDeletion) async {
        let account = pending.account
        do {
            AppLog.account.info("Deleting account \(account.id.uuidString, privacy: .public) for \(account.tool.rawValue, privacy: .public)")
            let provider = provider(for: account.tool)
            try await provider.deleteAccountArtifacts(account: account)
            try? quotaCacheStore.delete(accountID: account.id)
            if shouldStoreSecretInKeychain(for: account.tool) {
                try secretStore.deleteSecret(accountKey: secretStoreKey(for: account.id))
            }
            if pending.wasActive {
                await applyActiveSelectionToInstalledTool(account.tool)
            }
        } catch {
            AppLog.account.error("Delete account failed for \(account.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)")
            // The account row is already gone; surface the failure where the user can see it.
            showTransientNotice(text.deleteAccountFailedMessage(resolvedErrorMessage(error)))
        }
    }

    func activateAccount(_ account: Account) {
        let provider = provider(for: account.tool)

        Task {
            do {
                AppLog.account.info("Activating account \(account.id.uuidString, privacy: .public) for \(account.tool.rawValue, privacy: .public)")
                let secret = try await resolveSecret(for: account, provider: provider)
                let refreshedSecret = try await provider.refreshSecretIfNeeded(secret)
                if refreshedSecret != secret {
                    try await persistRefreshedSecret(
                        refreshedSecret,
                        previousSecret: secret,
                        account: account,
                        provider: provider
                    )
                }
                try await provider.activate(account: account, secret: refreshedSecret)
                activeAccountByTool[account.tool] = account.id
                try await persistState()
                let message = text.restartRequiredMessage(accountName: account.name, tool: account.tool)
                // Codex gets a dialog with a working "restart now" button as the only prompt —
                // the panel's notice bar stays hidden so the two never show together.
                if account.tool == .codex {
                    restartPromptPresenter?(account.tool, message)
                } else {
                    restartRequiredMessage = message
                    restartRequiredTool = account.tool
                }
                await refreshQuota(for: account, intent: .manual)
            } catch {
                AppLog.account.error("Activate account failed for \(account.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)")
                errorByAccount[account.id] = text.switchAccountFailedMessage(resolvedErrorMessage(error))
                errorRequiresUserActionByAccount[account.id] = errorRequiresUserAction(error)
                notifyAccountSwitchFailureIfDashboardHidden(account: account, error: error)
            }
        }
    }

    // Switching from the status-bar context menu happens with the panel closed; the card
    // footer error would be invisible, so failures also go out as a system notification.
    private func notifyAccountSwitchFailureIfDashboardHidden(account: Account, error: Error) {
        guard !isDashboardVisible else { return }
        notificationService.post(
            identifier: "switch-account-failed-\(account.id.uuidString)",
            title: text.switchAccountFailedNotificationTitle(tool: account.tool),
            body: resolvedErrorMessage(error)
        )
    }

    func dismissRestartRequiredMessage() {
        restartRequiredMessage = nil
        restartRequiredTool = nil
    }

    func dismissAddAccountError() {
        addAccountErrorMessage = nil
    }

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
        guard shouldRefreshAccounts(targetAccounts, freshnessInterval: dashboardOpenRefreshFreshnessInterval) else { return }

        primeRefreshState(for: targetAccounts)
        await refreshAccounts(targetAccounts, intent: .visible)
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
        checkForUpdatesAction = checkForUpdates
        installAvailableUpdateAction = installAvailableUpdate
        ignoreAvailableUpdateAction = ignoreAvailableUpdate
    }

    func checkForUpdatesFromDashboard() {
        checkForUpdatesAction?()
    }

    func installAvailableUpdateFromDashboard() {
        installAvailableUpdateAction?()
    }

    func ignoreAvailableUpdateFromDashboard() {
        ignoreAvailableUpdateAction?()
    }

    func registerLaunchAtLoginActions(
        isEnabled: @escaping () -> Bool,
        setEnabled: @escaping (Bool) -> Void
    ) {
        launchAtLoginEnabledProvider = isEnabled
        setLaunchAtLoginEnabledAction = setEnabled
        refreshLaunchAtLoginState()
    }

    func refreshLaunchAtLoginState() {
        isLaunchAtLoginEnabled = launchAtLoginEnabledProvider?() ?? false
    }

    func setLaunchAtLoginEnabledFromDashboard(_ enabled: Bool) {
        setLaunchAtLoginEnabledAction?(enabled)
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
        if enabled {
            notificationService.requestAuthorizationIfNeeded()
        }
    }

    func setQuotaNotificationThreshold(_ threshold: Double) {
        guard quotaNotificationThreshold != threshold else { return }
        quotaNotificationThreshold = threshold
        AppPreferencesStore.setQuotaNotificationThreshold(threshold)
    }

    func registerDashboardCloseAction(_ action: @escaping () -> Void) {
        closeDashboardAction = action
    }

    func closeDashboard() {
        closeDashboardAction?()
    }

    func registerToolRestartAction(_ action: @escaping (ToolKind) -> Void) {
        toolRestartAction = action
    }

    func registerRestartPromptPresenter(_ action: @escaping (ToolKind, String) -> Void) {
        restartPromptPresenter = action
    }

    var canRestartTool: Bool {
        // Only Cursor's restart is offered from the notice bar — Codex prompts via a dialog
        // (see activateAccount) and Claude Code remains a terminal session only the user
        // can restart.
        restartRequiredTool == .cursor && toolRestartAction != nil
    }

    func restartRequiredToolNow() {
        guard let tool = restartRequiredTool, canRestartTool else { return }
        toolRestartAction?(tool)
        dismissRestartRequiredMessage()
    }

    /// Direct restart for dialog-driven prompts, which carry their own tool context instead
    /// of going through the notice-bar state.
    func restartToolNow(_ tool: ToolKind) {
        toolRestartAction?(tool)
    }

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

    @discardableResult
    func addAccount(
        tool: ToolKind,
        name: String,
        secret: String,
        makeActive: Bool = true,
        useAsDefaultActive: Bool = true,
        applyToTool: Bool = true,
        refreshAfterAdd: Bool = true
    ) async throws -> Account {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = provider(for: tool)
        let detectedName = provider.suggestAccountName(from: secret) ?? AccountIdentityResolver.extractEmail(from: secret)
        let detectedIdentity = provider.accountIdentity(from: secret)
        let detectedIdentityAliases = provider.accountIdentityAliases(from: secret)

        if let duplicate = findDuplicateStoredAccount(
            for: tool,
            detectedIdentities: detectedIdentityAliases.isEmpty
                ? detectedIdentity.map { [$0] } ?? []
                : detectedIdentityAliases
        ) {
            var resolvedDuplicate = duplicate
            if shouldStoreSecretInKeychain(for: tool) {
                try secretStore.saveSecret(secret, accountKey: secretStoreKey(for: duplicate.id))
            }

            if let index = accounts.firstIndex(where: { $0.id == duplicate.id }) {
                let shouldRename = AccountIdentityResolver.looksAutoGeneratedName(accounts[index].name, tool: tool)
                    || accounts[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if shouldRename, let detectedName {
                    accounts[index].name = detectedName
                }

                let prepared = try await provider.prepareAccount(accounts[index], secret: secret)
                accounts[index] = prepared
                resolvedDuplicate = prepared
            }

            if makeActive {
                activeAccountByTool[tool] = duplicate.id
            } else if useAsDefaultActive && activeAccountByTool[tool] == nil {
                activeAccountByTool[tool] = duplicate.id
            }
            try await persistState()
            let syncedDuplicate = accounts.first(where: { $0.id == duplicate.id }) ?? resolvedDuplicate
            if let active = accounts.first(where: { $0.id == duplicate.id }) {
                if applyToTool, activeAccountByTool[tool] == active.id {
                    try await provider.activate(account: active, secret: secret)
                }
            }
            if refreshAfterAdd {
                await refreshQuota(for: syncedDuplicate, intent: .manual)
            }
            return syncedDuplicate
        }

        let resolvedName = AccountIdentityResolver.resolvedName(
            tool: tool,
            provider: provider,
            inputName: cleanedName,
            secret: secret
        )

        var account = Account(tool: tool, name: resolvedName)
        account = try await provider.prepareAccount(account, secret: secret)

        if shouldStoreSecretInKeychain(for: tool) {
            try secretStore.saveSecret(secret, accountKey: secretStoreKey(for: account.id))
        }

        accounts.append(account)
        if makeActive || (useAsDefaultActive && activeAccountByTool[tool] == nil) {
            activeAccountByTool[tool] = account.id
        }

        try await persistState()

        if applyToTool, activeAccountByTool[tool] == account.id {
            try await provider.activate(account: account, secret: secret)
        }

        if refreshAfterAdd {
            await refreshQuota(for: account, intent: .manual)
        }
        return account
    }

    private func normalizeActiveSelections() {
        activeAccountByTool = activeAccountByTool.filter { supportedTools.contains($0.key) }
        if !supportedTools.contains(selectedTool) {
            selectedTool = .codex
        }

        for tool in supportedTools {
            if let activeID = activeAccountByTool[tool], accounts.contains(where: { $0.id == activeID }) {
                continue
            }
            activeAccountByTool[tool] = nil
        }
    }

    private func loadPersistedStateForImmediateDisplay() {
        do {
            let state = try AccountStore.loadImmediately()
            applyPersistedState(state)
            normalizeActiveSelections()
            loadCachedQuotaSnapshots()
        } catch {
            AppLog.app.error("Failed to load immediate persisted state: \(String(describing: error), privacy: .private)")
        }
    }

    private func applyPersistedState(_ state: PersistedState) {
        accounts = state.accounts
        activeAccountByTool = state.activeAccountByTool.filter { supportedTools.contains($0.key) }
        selectedTool = [.codex, .cursor, .claudeCode]
            .first { activeAccountByTool[$0] != nil }
            ?? .codex
    }

    func persistState() async throws {
        let state = PersistedState(
            accounts: accounts,
            activeAccountByTool: activeAccountByTool
        )
        try await accountStore.save(state)
    }

    private func secretStoreKey(for accountID: UUID) -> String {
        "account.\(accountID.uuidString).secret"
    }

    private func shouldStoreSecretInKeychain(for tool: ToolKind) -> Bool {
        supportedTools.contains(tool)
    }

    func persistRefreshedSecret(
        _ secret: String,
        previousSecret: String,
        account: Account,
        provider: any Provider
    ) async throws {
        guard secret != previousSecret else { return }
        let isActive = activeAccountByTool[account.tool] == account.id
        if shouldStoreSecretInKeychain(for: account.tool) {
            try secretStore.saveSecret(secret, accountKey: secretStoreKey(for: account.id))
        }
        try await provider.persistRefreshedSecret(secret, for: account, isActive: isActive)
        if isActive {
            try await provider.updateCurrentCredentials(secret)
        }
    }

    private func loadCachedQuotaSnapshots() {
        for account in accounts where supportedTools.contains(account.tool) {
            guard quotaByAccount[account.id] == nil,
                  let cached = try? quotaCacheStore.load(accountID: account.id, tool: account.tool) else {
                continue
            }
            let snapshot = cached.removingExpiredWindows()
            let cachedSource = snapshot.source.lowercased().contains("cache")
                ? snapshot.source
                : "\(snapshot.source) Cache"
            quotaByAccount[account.id] = snapshot.replacing(source: cachedSource)
            loadStateByAccount[account.id] = loadStateForCachedSnapshot(snapshot)
        }
    }

    func provider(for tool: ToolKind) -> any Provider {
        providerRegistry.provider(for: tool)
    }

    private func normalizeAccountNamesIfNeeded() async {
        var didChange = false

        for index in accounts.indices {
            let account = accounts[index]
            guard supportedTools.contains(account.tool) else { continue }
            guard AccountIdentityResolver.looksAutoGeneratedName(account.name, tool: account.tool) else { continue }
            let provider = provider(for: account.tool)
            guard let secret = try? await resolveSecret(for: account, provider: provider) else { continue }

            if let identity = provider.accountIdentity(from: secret)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !identity.isEmpty,
               accounts[index].settings.identityKey != identity {
                accounts[index].settings.identityKey = identity
                didChange = true
            }

            guard let readable = provider.suggestAccountName(from: secret) ?? AccountIdentityResolver.extractEmail(from: secret) else { continue }

            if accounts[index].name != readable {
                accounts[index].name = readable
                didChange = true
            }
        }

        if didChange {
            try? await persistState()
        }
    }

    func resolveSecret(for account: Account, provider: any Provider) async throws -> String {
        var recoveryError: Error?
        do {
            if let recovered = try await provider.recoverSecret(for: account),
               !recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return recovered
            }
        } catch {
            recoveryError = error
            if !shouldStoreSecretInKeychain(for: account.tool) {
                throw error
            }
        }

        guard shouldStoreSecretInKeychain(for: account.tool) else {
            throw recoveryError ?? SecretStoreError.missingData
        }

        do {
            return try secretStore.readSecret(accountKey: secretStoreKey(for: account.id))
        } catch SecretStoreError.missingData {
            if let recovered = try await provider.recoverSecret(for: account),
               !recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if shouldStoreSecretInKeychain(for: account.tool) {
                    try secretStore.saveSecret(recovered, accountKey: secretStoreKey(for: account.id))
                }
                return recovered
            }
            throw SecretStoreError.missingData
        }
    }

    private func findDuplicateStoredAccount(
        for tool: ToolKind,
        detectedIdentities: [String]
    ) -> Account? {
        let normalizedDetectedIdentities = Set(detectedIdentities.map(AccountIdentityResolver.normalizeIdentityName))
        guard !normalizedDetectedIdentities.isEmpty else { return nil }

        for account in accounts where account.tool == tool {
            if let storedIdentity = account.settings.identityKey.map(AccountIdentityResolver.normalizeIdentityName),
               normalizedDetectedIdentities.contains(storedIdentity) {
                return account
            }
        }

        return nil
    }

    func updateAccountIdentityIfNeeded(accountID: UUID, identity: String?) -> Bool {
        guard let identity = identity?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return false
        }

        let current = accounts[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != identity else { return false }

        let shouldPreferIdentity = AccountIdentityResolver.looksAutoGeneratedName(current, tool: accounts[index].tool)
            || (identity.contains("@") && !current.contains("@"))
            || current.isEmpty

        guard shouldPreferIdentity else { return false }
        accounts[index].name = identity
        return true
    }

    func updateAccountReadableNameIfNeeded(
        accountID: UUID,
        provider: any Provider,
        secret: String
    ) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return false
        }
        let current = accounts[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AccountIdentityResolver.looksAutoGeneratedName(current, tool: accounts[index].tool) || current.isEmpty else {
            return false
        }
        guard let detected = provider.suggestAccountName(from: secret)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detected.isEmpty,
              detected != current else {
            return false
        }
        accounts[index].name = detected
        return true
    }

    func updateAccountSettingsIfNeeded(
        accountID: UUID,
        provider: any Provider,
        secret: String
    ) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return false
        }
        guard let identity = provider.accountIdentity(from: secret)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty,
              accounts[index].settings.identityKey != identity else {
            return false
        }

        accounts[index].settings.identityKey = identity
        return true
    }

}
