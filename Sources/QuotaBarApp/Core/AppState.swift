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
    private let secretStore: SecretStoreService
    let quotaCacheStore = QuotaSnapshotCacheStore()
    private let providerRegistry: ProviderRegistry
    let refreshBackoffPolicy = RefreshBackoffPolicy()
    let refreshIntervalPolicy = RefreshIntervalPolicy()
    let notificationService = QuotaNotificationService()
    private var hostActions = AppHostActions()

    var refreshTask: Task<Void, Never>?
    var dashboardRefreshTask: Task<Void, Never>?
    private var addAccountTask: Task<Void, Never>?
    private var addAccountOperationID: UUID?
    private var transientNoticeTask: Task<Void, Never>?
    var pendingDeletion: PendingAccountDeletion?
    var finalizingDeletionAccounts: [UUID: Account] = [:]

    struct PendingAccountDeletion {
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
    var refreshingToolByAccountID: [UUID: ToolKind] = [:]
    var activatingTools: Set<ToolKind> = []
    var credentialSyncCountByTool: [ToolKind: Int] = [:]
    var refreshFailureCountByAccount: [UUID: Int] = [:]
    var refreshBackoffUntilByAccount: [UUID: Date] = [:]
    var lastUsageRefreshByTool: [ToolKind: Date] = [:]
    var resetRefreshTasks: [UUID: Task<Void, Never>] = [:]
    struct PendingRestartReassertion: Equatable {
        let accountID: UUID
        // Distinguishes successive restarts of the same tool so a superseded watcher finishing late
        // cannot tear down the window its replacement just opened.
        let token: UUID
    }
    // The account each tool must still be signed into once the restart QuotaBar just triggered has
    // settled. Non-nil only inside that short window; see reassertActiveSelectionAfterRestart.
    var restartReassertionByTool: [ToolKind: PendingRestartReassertion] = [:]
    var restartReassertionTasks: [ToolKind: Task<Void, Never>] = [:]
    // Processes bounced by a restart rewrite their credential files at wildly different moments: a
    // terminal `codex` flushes on SIGTERM, a host app only once it has quit (CodexRestartService
    // waits up to 10s for that), relaunched, and restored its own session. Re-check across that
    // whole spread — gaps between successive checks, ~25s in total — instead of sampling once.
    let restartReassertionCheckpoints: [TimeInterval] = [1.5, 2, 3, 4, 6, 8]
    let maxConcurrentRefreshes = 4
    let autoRefreshJitter = RefreshIntervalPolicy.jitterInterval
    // Floor for the background loop's polling tick. The tick only re-evaluates freshness; it is the
    // per-account gate that decides what reaches the network.
    static let minimumAutoRefreshTick: TimeInterval = 45
    let foregroundRefreshFreshnessInterval: TimeInterval = 30
    let dashboardOpenRefreshFreshnessInterval: TimeInterval = 25
    let dashboardVisibleRefreshInterval: TimeInterval = 30
    // Coalesce usage-triggered refreshes: while a tool is actively used, its activity file changes
    // constantly, so cap live fetches to at most one per this interval (near-real-time, API-safe).
    let usageSignalMinRefreshInterval: TimeInterval = 10
    // A quota window flips back to full at a known instant; refresh just after it so the reset shows
    // immediately instead of waiting for the next periodic tick. The leeway lets the server flip first.
    let resetBoundaryRefreshLeeway: TimeInterval = 10
    var supportedTools: [ToolKind] { providerRegistry.supportedTools }

    init(
        secretStore: SecretStoreService = SecretStoreService(),
        providerRegistry: ProviderRegistry = ProviderRegistry()
    ) {
        self.secretStore = secretStore
        self.providerRegistry = providerRegistry
    }

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
            await migrateLegacyClaudeIdentityKeys()
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
        resetRefreshTasks.values.forEach { $0.cancel() }
        resetRefreshTasks.removeAll()
        restartReassertionTasks.values.forEach { $0.cancel() }
        restartReassertionTasks.removeAll()
        restartReassertionByTool.removeAll()
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
           !importedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if storedDuplicate(for: tool, provider: provider, secret: importedSecret) == nil {
                return QuickAddSecretResult(secret: importedSecret, matchesExistingAccount: false)
            }
            // The tool is signed into an account we already store, so the user is about to add a
            // DIFFERENT one via the browser — which overwrites the tool's live credentials. Sync
            // the live (possibly rotated, single-use) token pair into the stored card first, or
            // the stored copy may hold an already-consumed refresh token and die the moment the
            // login replaces the tool's own copy.
            _ = try? await addAccount(
                tool: tool,
                name: "",
                secret: importedSecret,
                makeActive: false,
                useAsDefaultActive: false,
                applyToTool: false,
                refreshAfterAdd: false
            )
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
        finalizingDeletionAccounts[pending.account.id] = pending.account
        defer { finalizingDeletionAccounts.removeValue(forKey: pending.account.id) }
        await performPhysicalDeletion(pending)
    }

    private func finalizePendingDeletionNow() {
        guard let pending = pendingDeletion else { return }
        pending.finalizeTask?.cancel()
        pendingDeletion = nil
        finalizingDeletionAccounts[pending.account.id] = pending.account
        Task {
            await performPhysicalDeletion(pending)
            finalizingDeletionAccounts.removeValue(forKey: pending.account.id)
        }
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
                await applyActiveSelectionToInstalledTool(account.tool, discardedAccount: account)
            }
        } catch {
            AppLog.account.error("Delete account failed for \(account.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)")
            // The account row is already gone; surface the failure where the user can see it.
            showTransientNotice(text.deleteAccountFailedMessage(resolvedErrorMessage(error)))
        }
    }

    func activateAccount(_ account: Account) {
        Task {
            do {
                AppLog.account.info("Activating account \(account.id.uuidString, privacy: .public) for \(account.tool.rawValue, privacy: .public)")
                try await performAccountActivation(
                    account,
                    captureMissingCurrentAccount: true,
                    discardedAccount: nil
                )
                let message = text.restartRequiredMessage(accountName: account.name, tool: account.tool)
                // Codex gets a dialog with a working "restart now" button as the only prompt —
                // the panel's notice bar stays hidden so the two never show together.
                if account.tool == .codex {
                    hostActions.presentRestartPrompt?(account.tool, message)
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

    /// Serializes the full Claude replacement transaction: finish every in-flight Claude refresh,
    /// capture the live pair, renew the detached target if needed, then resolve and install it.
    func performAccountActivation(
        _ account: Account,
        captureMissingCurrentAccount: Bool,
        discardedAccount: Account?
    ) async throws {
        let provider = provider(for: account.tool)
        guard account.tool == .claudeCode else {
            let secret = try await resolveSecret(for: account, provider: provider)
            var refreshedSecret = try await provider.refreshSecretIfNeeded(secret)
            if refreshedSecret != secret {
                refreshedSecret = try await persistRefreshedSecret(
                    refreshedSecret,
                    previousSecret: secret,
                    expectedStoredSecret: nil,
                    account: account,
                    provider: provider
                )
            }
            try await provider.activate(account: account, secret: refreshedSecret)
            activeAccountByTool[account.tool] = account.id
            // Activation rewrites the tool's credential file, which the watcher reports right back.
            // Record the signature we just installed so that echo is recognised as our own work
            // rather than an external switch worth re-importing.
            credentialSignatureByTool[account.tool] = credentialEventSignature(
                secret: refreshedSecret,
                provider: provider
            )
            try await persistState()
            return
        }

        guard activatingTools.insert(account.tool).inserted else {
            throw ProviderError.unsupported("Claude Code 账号切换正在进行，请稍后重试。")
        }
        defer { activatingTools.remove(account.tool) }

        while refreshingToolByAccountID.values.contains(account.tool)
            || (credentialSyncCountByTool[account.tool] ?? 0) > 0 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard await captureInstalledCurrentAccountBeforeReplacement(
            for: account.tool,
            captureMissingAccount: captureMissingCurrentAccount,
            discardedAccount: discardedAccount
        ) else {
            throw ProviderError.unsupported("未能在不弹出授权窗口的前提下安全读取当前 Claude Code 凭据，已取消切换。")
        }

        let secret = try await resolveSecret(for: account, provider: provider)
        let storedSecretAtStart = try? secretStore.readSecret(accountKey: secretStoreKey(for: account.id))
        let reconciledSecret = if let storedSecretAtStart {
            (try? provider.reconcileImportedSecret(
                secret,
                withStoredSecret: storedSecretAtStart
            )) ?? secret
        } else {
            secret
        }
        var refreshedSecret = try await provider.refreshSecretIfNeeded(reconciledSecret)
        if refreshedSecret != reconciledSecret
            || (storedSecretAtStart != nil && refreshedSecret != storedSecretAtStart) {
            refreshedSecret = try await persistRefreshedSecret(
                refreshedSecret,
                previousSecret: reconciledSecret,
                expectedStoredSecret: storedSecretAtStart,
                account: account,
                provider: provider
            )
        }
        try await provider.activate(account: account, secret: refreshedSecret)
        activeAccountByTool[account.tool] = account.id
        try await persistState()
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
    func scheduleActiveSelectionReassertion(for tool: ToolKind) {
        // Claude Code has no app to restart, and its credentials live in a shared keychain entry
        // guarded by the activation transaction — re-writing them here would race that.
        guard tool != .claudeCode, let account = activeAccount(for: tool) else { return }

        let token = UUID()
        restartReassertionTasks[tool]?.cancel()
        restartReassertionByTool[tool] = PendingRestartReassertion(accountID: account.id, token: token)
        restartReassertionTasks[tool] = Task { [weak self] in
            await self?.reassertActiveSelectionAfterRestart(for: tool, account: account)
            await MainActor.run {
                guard let self, self.restartReassertionByTool[tool]?.token == token else { return }
                self.restartReassertionByTool.removeValue(forKey: tool)
                self.restartReassertionTasks.removeValue(forKey: tool)
            }
        }
    }

    private func reassertActiveSelectionAfterRestart(for tool: ToolKind, account: Account) async {
        let provider = provider(for: tool)
        var didReassert = false

        for checkpoint in restartReassertionCheckpoints {
            try? await Task.sleep(nanoseconds: UInt64(checkpoint * 1_000_000_000))
            guard !Task.isCancelled, activeAccountByTool[tool] == account.id else { return }

            guard let installed = try? await provider.importCurrentCredentials(),
                  !installed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !installedCredentials(installed, belongTo: account, provider: provider) else {
                continue
            }

            do {
                let secret = try await resolveSecret(for: account, provider: provider)
                try await provider.activate(account: account, secret: secret)
                // Our own write must not read back as an external account change.
                credentialSignatureByTool[tool] = credentialEventSignature(secret: secret, provider: provider)
                didReassert = true
                AppLog.account.info("Restarted \(tool.rawValue, privacy: .public) came back on a different account; restored \(account.id.uuidString, privacy: .public)")
            } catch {
                AppLog.account.error("Failed to restore \(account.id.uuidString, privacy: .public) after \(tool.rawValue, privacy: .public) restart: \(String(describing: error), privacy: .private)")
                return
            }
        }

        if didReassert {
            await refreshQuota(for: account, intent: .manual)
        }
    }

    /// True when the tool's installed credentials still describe `account`. Accounts stored before
    /// identity metadata existed carry no key; treat those as a match so the re-assertion stays
    /// silent instead of rewriting credentials it cannot actually verify.
    func installedCredentials(
        _ secret: String,
        belongTo account: Account,
        provider: any Provider
    ) -> Bool {
        guard account.settings.identityKey != nil else { return true }
        let aliases = provider.accountIdentityAliases(from: secret)
        let detected = aliases.isEmpty
            ? provider.accountIdentity(from: secret).map { [$0] } ?? []
            : aliases
        guard !detected.isEmpty else { return true }
        return Self.accountIdentity(account.settings.identityKey, matchesAny: detected)
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
            var reconciledSecret = secret
            if shouldStoreSecretInKeychain(for: tool) {
                if let storedSecret = try? secretStore.readSecret(accountKey: secretStoreKey(for: duplicate.id)) {
                    reconciledSecret = (try? provider.reconcileImportedSecret(
                        secret,
                        withStoredSecret: storedSecret
                    )) ?? secret
                    if reconciledSecret != storedSecret {
                        try secretStore.saveSecret(reconciledSecret, accountKey: secretStoreKey(for: duplicate.id))
                    }
                } else {
                    try secretStore.saveSecret(reconciledSecret, accountKey: secretStoreKey(for: duplicate.id))
                }
            }

            if let index = accounts.firstIndex(where: { $0.id == duplicate.id }) {
                let shouldRename = AccountIdentityResolver.looksAutoGeneratedName(accounts[index].name, tool: tool)
                    || accounts[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if shouldRename, let detectedName {
                    accounts[index].name = detectedName
                }

                let prepared = try await provider.prepareAccount(accounts[index], secret: reconciledSecret)
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
                    try await provider.activate(account: active, secret: reconciledSecret)
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

    func storedSecretSnapshot(for account: Account) -> String? {
        guard shouldStoreSecretInKeychain(for: account.tool) else { return nil }
        return try? secretStore.readSecret(accountKey: secretStoreKey(for: account.id))
    }

    private func shouldStoreSecretInKeychain(for tool: ToolKind) -> Bool {
        supportedTools.contains(tool)
    }

    func persistRefreshedSecret(
        _ secret: String,
        previousSecret: String,
        expectedStoredSecret: String?,
        account: Account,
        provider: any Provider
    ) async throws -> String {
        guard secret != previousSecret
            || (expectedStoredSecret != nil && secret != expectedStoredSecret) else {
            return secret
        }
        let isActive = activeAccountByTool[account.tool] == account.id
        if shouldStoreSecretInKeychain(for: account.tool) {
            if account.tool == .claudeCode {
                // A statusLine event may capture a newer single-use pair while this refresh is
                // suspended. Compare against the exact stored value seen at the start and never
                // let the older result overwrite a store that has advanced in the meantime.
                guard let expectedStoredSecret else { return secret }
                let currentStoredSecret = try secretStore.readSecret(
                    accountKey: secretStoreKey(for: account.id)
                )
                guard currentStoredSecret == expectedStoredSecret else {
                    return currentStoredSecret
                }
            }
            try secretStore.saveSecret(secret, accountKey: secretStoreKey(for: account.id))
        }
        try await provider.persistRefreshedSecret(secret, for: account, isActive: isActive)
        if isActive {
            try await provider.updateCurrentCredentials(secret)
        }
        return secret
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

    // Claude Code identity keys used to be derived from `~/.claude.json`'s `userID`, which the
    // CLI mints once per installation and never rotates on login — every account on the machine
    // shared it, so adding a second account merged it into the first one's card. Re-key stored
    // accounts from their own secrets before the launch-time credential sync runs, or that sync
    // would fail to match the migrated aliases and create a duplicate card.
    private func migrateLegacyClaudeIdentityKeys() async {
        let provider = provider(for: .claudeCode)
        var changed = false
        for index in accounts.indices where accounts[index].tool == .claudeCode {
            let currentKey = accounts[index].settings.identityKey?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized = currentKey?.lowercased(),
               normalized.hasPrefix("claude-code:account:") || normalized.hasPrefix("claude-code:email:") {
                continue
            }
            guard let secret = try? await resolveSecret(for: accounts[index], provider: provider),
                  let identity = provider.accountIdentity(from: secret)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !identity.isEmpty,
                  identity.lowercased() != currentKey?.lowercased() else {
                continue
            }
            let normalizedIdentity = identity.lowercased()
            guard normalizedIdentity.hasPrefix("claude-code:account:")
                || normalizedIdentity.hasPrefix("claude-code:email:") else {
                continue
            }
            accounts[index].settings.identityKey = identity
            changed = true
            AppLog.account.info("Migrated legacy Claude identity key for account \(self.accounts[index].id.uuidString, privacy: .public)")
        }
        if changed {
            try? await persistState()
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

    /// Captures the installed account without changing QuotaBar's active selection. A deleted
    /// account may be intentionally discarded; any other untracked account is preserved first.
    func captureInstalledCurrentAccountBeforeReplacement(
        for tool: ToolKind,
        captureMissingAccount: Bool,
        discardedAccount: Account?
    ) async -> Bool {
        let provider = provider(for: tool)
        do {
            let secret = try await provider.importCurrentCredentials()
            guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  provider.canSafelyReplaceInstalledCredentials(afterImport: secret) else {
                return false
            }

            let aliases = provider.accountIdentityAliases(from: secret)
            let detectedIdentities = aliases.isEmpty
                ? provider.accountIdentity(from: secret).map { [$0] } ?? []
                : aliases
            let existing = findDuplicateStoredAccount(
                for: tool,
                detectedIdentities: detectedIdentities
            )
            if existing == nil, !captureMissingAccount {
                guard let discardedIdentity = discardedAccount?.settings.identityKey
                    .map(AccountIdentityResolver.normalizeIdentityName) else {
                    return false
                }
                let normalizedDetected = Set(
                    detectedIdentities.map(AccountIdentityResolver.normalizeIdentityName)
                )
                return normalizedDetected.contains(discardedIdentity)
            }

            _ = try await addAccount(
                tool: tool,
                name: "",
                secret: secret,
                makeActive: false,
                useAsDefaultActive: false,
                applyToTool: false,
                refreshAfterAdd: false
            )
            return true
        } catch {
            AppLog.account.error("Failed to capture installed \(tool.rawValue, privacy: .public) credentials before replacement: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// A statusLine event can arrive while its active Claude account is hidden for undo. Keep the
    /// captured token pair with that pending account, but never recreate or reactivate its row.
    func absorbCredentialSyncForPendingDeletion(
        tool: ToolKind,
        provider: any Provider,
        secret: String
    ) -> Bool {
        let aliases = provider.accountIdentityAliases(from: secret)
        let detectedIdentities = aliases.isEmpty
            ? provider.accountIdentity(from: secret).map { [$0] } ?? []
            : aliases
        if finalizingDeletionAccounts.values.contains(where: {
            $0.tool == tool
                && Self.accountIdentity($0.settings.identityKey, matchesAny: detectedIdentities)
        }) {
            return true
        }
        guard let pending = pendingDeletion,
              pending.account.tool == tool,
              Self.accountIdentity(
                  pending.account.settings.identityKey,
                  matchesAny: detectedIdentities
              ) else {
            return false
        }

        if shouldStoreSecretInKeychain(for: tool),
           provider.canSafelyReplaceInstalledCredentials(afterImport: secret) {
            var reconciledSecret = secret
            if let storedSecret = try? secretStore.readSecret(accountKey: secretStoreKey(for: pending.account.id)) {
                reconciledSecret = (try? provider.reconcileImportedSecret(
                    secret,
                    withStoredSecret: storedSecret
                )) ?? secret
            }
            do {
                try secretStore.saveSecret(
                    reconciledSecret,
                    accountKey: secretStoreKey(for: pending.account.id)
                )
            } catch {
                AppLog.account.error("Failed to update pending-deletion \(tool.rawValue, privacy: .public) credentials: \(String(describing: error), privacy: .private)")
            }
        }
        return true
    }

    static func accountIdentity(_ identity: String?, matchesAny candidates: [String]) -> Bool {
        guard let identity else { return false }
        let normalizedIdentity = AccountIdentityResolver.normalizeIdentityName(identity)
        return candidates
            .map(AccountIdentityResolver.normalizeIdentityName)
            .contains(normalizedIdentity)
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
