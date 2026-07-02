import CryptoKit
import Foundation

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
    @Published var language: AppLanguage = .stored
    @Published var restartRequiredMessage: String?
    @Published var addAccountErrorMessage: String?
    @Published var updateBannerState: AppUpdateBannerState = .idle
    @Published var isLaunchAtLoginEnabled = false
    @Published var isRefreshOnOpenEnabled: Bool = AppPreferencesStore.refreshOnOpenEnabled
    @Published var recommendationStrategy: AccountRecommendationStrategy = AppPreferencesStore.recommendationStrategy
    @Published var menuBarVisibleTools: Set<ToolKind> = AppPreferencesStore.menuBarVisibleTools

    private let accountStore = AccountStore()
    private let secretStore = SecretStoreService()
    private let quotaCacheStore = QuotaSnapshotCacheStore()
    private let providerRegistry = ProviderRegistry()
    private let refreshBackoffPolicy = RefreshBackoffPolicy()
    private let refreshIntervalPolicy = RefreshIntervalPolicy()
    private var checkForUpdatesAction: (() -> Void)?
    private var installAvailableUpdateAction: (() -> Void)?
    private var launchAtLoginEnabledProvider: (() -> Bool)?
    private var setLaunchAtLoginEnabledAction: ((Bool) -> Void)?

    private var refreshTask: Task<Void, Never>?
    private var dashboardRefreshTask: Task<Void, Never>?
    private var addAccountTask: Task<Void, Never>?
    private var addAccountOperationID: UUID?
    private var refreshEventMonitor: RefreshEventMonitor?
    private var refreshEventTasks: [RefreshEventReason: Task<Void, Never>] = [:]
    private var credentialSignatureByTool: [ToolKind: String] = [:]
    private var isDashboardVisible = false
    private var dashboardVisibleAccountIDs: [UUID] = []
    private var refreshingAccountIDs: Set<UUID> = []
    private var refreshFailureCountByAccount: [UUID: Int] = [:]
    private var refreshBackoffUntilByAccount: [UUID: Date] = [:]
    private let maxConcurrentRefreshes = 4
    private let autoRefreshJitter = RefreshIntervalPolicy.jitterInterval
    private let foregroundRefreshFreshnessInterval: TimeInterval = 30
    private let dashboardOpenRefreshFreshnessInterval: TimeInterval = 25
    private let dashboardVisibleRefreshInterval: TimeInterval = 30
    private var supportedTools: [ToolKind] { providerRegistry.supportedTools }

    private var supportedToolsPrioritizingSelectedTool: [ToolKind] {
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
        refreshTask?.cancel()
        dashboardRefreshTask?.cancel()
        addAccountTask?.cancel()
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
                }
            }

            let provider = provider(for: tool)
            do {
                try Task.checkCancellation()
                let secret = try await provider.authenticateViaBrowser()
                try Task.checkCancellation()
                try await addAccount(
                    tool: tool,
                    name: "",
                    secret: secret,
                    makeActive: false,
                    useAsDefaultActive: false,
                    applyToTool: false
                )
            } catch is CancellationError {
            } catch {
                AppLog.account.error("Add account failed for \(tool.rawValue, privacy: .public): \(String(describing: error), privacy: .private)")
                addAccountErrorMessage = text.addAccountFailedMessage(resolvedErrorMessage(error))
            }
        }
    }

    func cancelAddAccount() {
        guard isAddingAccount else { return }
        addAccountTask?.cancel()
        addAccountTask = nil
        addAccountOperationID = nil
        isAddingAccount = false
    }

    func deleteAccount(_ account: Account) {
        Task {
            do {
                AppLog.account.info("Deleting account \(account.id.uuidString, privacy: .public) for \(account.tool.rawValue, privacy: .public)")
                let provider = provider(for: account.tool)
                try await provider.deleteAccountArtifacts(account: account)

                accounts.removeAll { $0.id == account.id }
                quotaByAccount[account.id] = nil
                errorByAccount[account.id] = nil
                errorRequiresUserActionByAccount[account.id] = nil
                loadStateByAccount[account.id] = nil
                try? quotaCacheStore.delete(accountID: account.id)
                if shouldStoreSecretInKeychain(for: account.tool) {
                    try secretStore.deleteSecret(accountKey: secretStoreKey(for: account.id))
                }

                if activeAccountByTool[account.tool] == account.id {
                    activeAccountByTool[account.tool] = accounts.first(where: { $0.tool == account.tool })?.id
                    await applyActiveSelectionToInstalledTool(account.tool)
                }

                try await persistState()
            } catch {
                AppLog.account.error("Delete account failed for \(account.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)")
                errorByAccount[account.id] = text.deleteAccountFailedMessage(resolvedErrorMessage(error))
                errorRequiresUserActionByAccount[account.id] = errorRequiresUserAction(error)
            }
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
                restartRequiredMessage = text.restartRequiredMessage(accountName: account.name, tool: account.tool)
                await refreshQuota(for: account, intent: .manual)
            } catch {
                AppLog.account.error("Activate account failed for \(account.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)")
                errorByAccount[account.id] = text.switchAccountFailedMessage(resolvedErrorMessage(error))
                errorRequiresUserActionByAccount[account.id] = errorRequiresUserAction(error)
            }
        }
    }

    func dismissRestartRequiredMessage() {
        restartRequiredMessage = nil
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
        installAvailableUpdate: @escaping () -> Void
    ) {
        checkForUpdatesAction = checkForUpdates
        installAvailableUpdateAction = installAvailableUpdate
    }

    func checkForUpdatesFromDashboard() {
        checkForUpdatesAction?()
    }

    func installAvailableUpdateFromDashboard() {
        installAvailableUpdateAction?()
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
    private func addAccount(
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

    private func startAutoRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                let delay = automaticRefreshInterval() + Double.random(in: 0 ... autoRefreshJitter)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await refreshActiveAccounts()
            }
        }
    }

    private func refreshActiveAccounts(intent: RefreshIntent = .background) async {
        await syncInstalledCurrentAccounts()
        await refreshAccounts(
            supportedToolsPrioritizingSelectedTool.compactMap { activeAccount(for: $0) },
            intent: intent
        )
    }

    private func refreshActiveAccountsIfNeeded(freshnessInterval: TimeInterval, intent: RefreshIntent) async {
        await syncInstalledCurrentAccounts()
        let targetAccounts = supportedToolsPrioritizingSelectedTool
            .compactMap { activeAccount(for: $0) }
            .filter { shouldRefreshAccount($0, freshnessInterval: freshnessInterval) }
        await refreshAccounts(targetAccounts, intent: intent)
    }

    private func refreshActiveAccount(for tool: ToolKind, syncInstalled: Bool, intent: RefreshIntent) async {
        if syncInstalled {
            await syncInstalledCurrentAccount(for: tool)
        }
        guard let account = activeAccount(for: tool) else { return }
        await refreshQuota(for: account, intent: intent)
    }

    private func startDashboardRefreshLoop() {
        dashboardRefreshTask?.cancel()
        dashboardRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(dashboardVisibleRefreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await refreshDashboardVisibleAccountsIfNeeded()
            }
        }
    }

    private func refreshDashboardVisibleAccountsIfNeeded() async {
        guard isDashboardVisible else { return }
        let targetAccounts = dashboardVisibleAccounts()
            .filter { shouldRefreshAccount($0, freshnessInterval: dashboardVisibleRefreshInterval) }
        guard !targetAccounts.isEmpty else { return }

        await syncInstalledCurrentAccount(for: selectedTool)
        primeRefreshState(for: targetAccounts)
        await refreshAccounts(targetAccounts, intent: .visible)
    }

    private func dashboardVisibleAccounts() -> [Account] {
        let selectedAccounts = accounts(for: selectedTool)
        guard !dashboardVisibleAccountIDs.isEmpty else {
            return selectedAccounts
        }
        let visibleIDs = Set(dashboardVisibleAccountIDs)
        return selectedAccounts.filter { visibleIDs.contains($0.id) }
    }

    private func automaticRefreshInterval() -> TimeInterval {
        let activeRemainingRatios = supportedTools.compactMap { activeAccount(for: $0) }
            .compactMap { quotaByAccount[$0.id]?.statusBarMetric?.ratio }
        return refreshIntervalPolicy.automaticRefreshInterval(activeRemainingRatios: activeRemainingRatios)
    }

    private func startRefreshEventMonitor() {
        let monitor = RefreshEventMonitor { [weak self] reason in
            self?.handleRefreshEvent(reason)
        }
        refreshEventMonitor?.stop()
        refreshEventMonitor = monitor
        monitor.start(watchTargets: RefreshWatchTargetFactory().watchTargets())
    }

    private func handleRefreshEvent(_ reason: RefreshEventReason) {
        refreshEventTasks[reason]?.cancel()
        refreshEventTasks[reason] = Task { [weak self] in
            await self?.performRefreshEvent(reason)
            await MainActor.run {
                self?.refreshEventTasks[reason] = nil
            }
        }
    }

    private func performRefreshEvent(_ reason: RefreshEventReason) async {
        guard !Task.isCancelled else { return }
        switch reason {
        case .claudeStatusLineChanged:
            await refreshActiveAccount(for: .claudeCode, syncInstalled: false, intent: .background)
        case .credentialsChanged(let tool):
            await refreshAfterCredentialChange(for: tool)
        case .appForegrounded:
            await refreshActiveAccountsIfNeeded(freshnessInterval: foregroundRefreshFreshnessInterval, intent: .visible)
        case .systemWoke, .networkRestored:
            await refreshActiveAccounts(intent: .visible)
        }
    }

    private func refreshAfterCredentialChange(for tool: ToolKind) async {
        guard supportedTools.contains(tool) else { return }
        let provider = provider(for: tool)

        do {
            var secret = try await provider.importCurrentCredentials()
            guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            if let refreshed = try? await provider.refreshSecretIfNeeded(secret) {
                if refreshed != secret {
                    try? await provider.updateCurrentCredentials(refreshed)
                }
                secret = refreshed
            }

            let signature = credentialEventSignature(secret: secret, provider: provider)
            guard credentialSignatureByTool[tool] != signature else {
                AppLog.refresh.debug("Ignoring unchanged credential event for \(tool.rawValue, privacy: .public)")
                return
            }
            credentialSignatureByTool[tool] = signature

            let account = try await addAccount(
                tool: tool,
                name: "",
                secret: secret,
                makeActive: provider.treatsImportedCredentialsAsActiveSelection,
                useAsDefaultActive: provider.treatsImportedCredentialsAsActiveSelection,
                applyToTool: false,
                refreshAfterAdd: false
            )
            AppLog.refresh.info("Credential event refreshed active account \(account.id.uuidString, privacy: .public) for \(tool.rawValue, privacy: .public)")
            await refreshQuota(for: account, intent: .manual)
        } catch {
            AppLog.refresh.debug("Credential event ignored for \(tool.rawValue, privacy: .public): \(String(describing: error), privacy: .private)")
        }
    }

    private func refreshRemainingAccountsInBackground(excluding refreshedAccountIDs: Set<UUID>) async {
        let remainingAccounts = accounts.filter { account in
            supportedTools.contains(account.tool) && !refreshedAccountIDs.contains(account.id)
        }
        guard !remainingAccounts.isEmpty else { return }
        await refreshAccounts(remainingAccounts, intent: .background)
    }

    private func applyActiveSelectionsToInstalledTools() async {
        for tool in supportedToolsPrioritizingSelectedTool {
            await applyActiveSelectionToInstalledTool(tool)
        }
    }

    private func applyActiveSelectionToInstalledTool(_ tool: ToolKind) async {
        guard let account = activeAccount(for: tool) else { return }
        let provider = provider(for: tool)
        do {
            let secret = try await resolveSecret(for: account, provider: provider)
            try await provider.activate(account: account, secret: secret)
        } catch {
            AppLog.account.error("Apply active selection failed for \(account.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)")
            errorByAccount[account.id] = text.switchAccountFailedMessage(resolvedErrorMessage(error))
            errorRequiresUserActionByAccount[account.id] = errorRequiresUserAction(error)
            loadStateByAccount[account.id] = quotaByAccount[account.id] == nil ? .failed : .stale
        }
    }

    private func syncInstalledCredentialsAtLaunch() async {
        for tool in supportedToolsPrioritizingSelectedTool {
            let provider = provider(for: tool)

            if let codexProvider = provider as? CodexProvider,
               let snapshots = try? await codexProvider.importStoredAccounts() {
                AppLog.account.info("Importing stored Codex accounts: \(snapshots.count, privacy: .public)")
                for snapshot in snapshots {
                    do {
                        try await addAccount(
                            tool: tool,
                            name: snapshot.name,
                            secret: snapshot.secret,
                            makeActive: activeAccountByTool[tool] == nil && snapshot.isActive,
                            useAsDefaultActive: snapshot.isActive,
                            applyToTool: false,
                            refreshAfterAdd: false
                        )
                    } catch {
                        AppLog.account.error("Stored Codex import skipped after error: \(String(describing: error), privacy: .private)")
                        continue
                    }
                }
            }

            await syncInstalledCurrentAccount(for: tool)
        }
    }

    private func syncInstalledCurrentAccounts() async {
        for tool in supportedToolsPrioritizingSelectedTool {
            await syncInstalledCurrentAccount(for: tool)
        }
    }

    @discardableResult
    private func syncInstalledCurrentAccount(for tool: ToolKind) async -> Account? {
        guard supportedTools.contains(tool) else { return nil }
        let provider = provider(for: tool)

        do {
            var secret = try await provider.importCurrentCredentials()
            guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            if let refreshed = try? await provider.refreshSecretIfNeeded(secret) {
                if refreshed != secret {
                    try? await provider.updateCurrentCredentials(refreshed)
                }
                secret = refreshed
            }
            credentialSignatureByTool[tool] = credentialEventSignature(secret: secret, provider: provider)

            let account = try await addAccount(
                tool: tool,
                name: "",
                secret: secret,
                makeActive: provider.treatsImportedCredentialsAsActiveSelection,
                useAsDefaultActive: provider.treatsImportedCredentialsAsActiveSelection,
                applyToTool: false,
                refreshAfterAdd: false
            )
            AppLog.account.info("Synced installed current account \(account.id.uuidString, privacy: .public) for \(tool.rawValue, privacy: .public)")
            return account
        } catch {
            AppLog.account.debug("No current credentials imported for \(tool.rawValue, privacy: .public): \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private func credentialEventSignature(secret: String, provider: any Provider) -> String {
        let aliases = provider.accountIdentityAliases(from: secret)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        if !aliases.isEmpty {
            return aliases.joined(separator: "|")
        }

        if let identity = provider.accountIdentity(from: secret)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identity.isEmpty {
            return identity
        }

        let digest = SHA256.hash(data: Data(secret.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func refreshAccounts(_ targetAccounts: [Account], intent: RefreshIntent = .background) async {
        guard !targetAccounts.isEmpty else { return }

        var startIndex = targetAccounts.startIndex
        while startIndex < targetAccounts.endIndex {
            let endIndex = targetAccounts.index(startIndex, offsetBy: maxConcurrentRefreshes, limitedBy: targetAccounts.endIndex)
                ?? targetAccounts.endIndex
            let batch = Array(targetAccounts[startIndex ..< endIndex])

            await withTaskGroup(of: Void.self) { group in
                for account in batch {
                    group.addTask { [weak self] in
                        await self?.refreshQuota(for: account, intent: intent)
                    }
                }
            }

            startIndex = endIndex
        }
    }

    private func primeRefreshState(for targetAccounts: [Account]) {
        for account in targetAccounts where supportedTools.contains(account.tool) {
            guard !refreshingAccountIDs.contains(account.id) else { continue }
            loadStateByAccount[account.id] = quotaByAccount[account.id] == nil ? .loadingInitial : .refreshing
        }
    }

    private func shouldRefreshForForegroundDisplay(_ targetAccounts: [Account]) -> Bool {
        shouldRefreshAccounts(targetAccounts, freshnessInterval: foregroundRefreshFreshnessInterval)
    }

    private func shouldRefreshAccounts(_ targetAccounts: [Account], freshnessInterval: TimeInterval) -> Bool {
        targetAccounts.contains { shouldRefreshAccount($0, freshnessInterval: freshnessInterval) }
    }

    private func shouldRefreshAccount(_ account: Account, freshnessInterval: TimeInterval) -> Bool {
        guard supportedTools.contains(account.tool) else { return false }
        if refreshingAccountIDs.contains(account.id) {
            return false
        }

        let effectiveFreshnessInterval = effectiveFreshnessInterval(for: account, default: freshnessInterval)

        switch loadStateByAccount[account.id] {
        case .loadingInitial, .refreshing:
            return false
        case .failed:
            return true
        case .stale:
            guard let snapshot = quotaByAccount[account.id] else { return true }
            return QuotaFreshness.isStale(snapshot)
                || Date().timeIntervalSince(snapshot.updatedAt) > effectiveFreshnessInterval
        case .idle, .none:
            return quotaByAccount[account.id] == nil
        case .loaded:
            guard let snapshot = quotaByAccount[account.id] else { return true }
            return Date().timeIntervalSince(snapshot.updatedAt) > effectiveFreshnessInterval
        }
    }

    private func effectiveFreshnessInterval(for account: Account, default freshnessInterval: TimeInterval) -> TimeInterval {
        guard account.tool == .claudeCode,
              let snapshot = quotaByAccount[account.id],
              QuotaFreshness.isStale(snapshot) else {
            return freshnessInterval
        }
        return min(freshnessInterval, 30)
    }

    private func loadStateAfterFailedRefresh(for account: Account) -> AccountLoadState {
        guard let snapshot = quotaByAccount[account.id] else {
            return .failed
        }
        return QuotaFreshness.isStale(snapshot) ? .stale : .loaded
    }

    private func loadStateForCachedSnapshot(_ snapshot: QuotaSnapshot) -> AccountLoadState {
        QuotaFreshness.isStale(snapshot) ? .stale : .loaded
    }

    private func refreshQuota(for account: Account, intent: RefreshIntent = .background) async {
        guard !refreshingAccountIDs.contains(account.id) else { return }
        if intent.bypassesAppBackoff {
            refreshBackoffUntilByAccount[account.id] = nil
        } else if let retryAt = refreshBackoffUntilByAccount[account.id], retryAt > Date() {
            AppLog.refresh.debug("Skipping account \(account.id.uuidString, privacy: .public) until \(retryAt, privacy: .public)")
            return
        }
        let provider = provider(for: account.tool)
        let hadSnapshot = quotaByAccount[account.id] != nil

        AppLog.refresh.info("Refreshing account \(account.id.uuidString, privacy: .public) for \(account.tool.rawValue, privacy: .public), intent=\(intent.rawValue, privacy: .public)")
        refreshingAccountIDs.insert(account.id)
        loadStateByAccount[account.id] = hadSnapshot ? .refreshing : .loadingInitial
        defer {
            refreshingAccountIDs.remove(account.id)
            if loadStateByAccount[account.id] == .refreshing || loadStateByAccount[account.id] == .loadingInitial {
                loadStateByAccount[account.id] = quotaByAccount[account.id] == nil ? .idle : .loaded
            }
        }

        do {
            let secret = try await resolveSecret(for: account, provider: provider)
            var refreshedSecret = try await provider.refreshSecretIfNeeded(secret)
            if refreshedSecret != secret {
                try await persistRefreshedSecret(
                    refreshedSecret,
                    previousSecret: secret,
                    account: account,
                    provider: provider
                )
            }

            let snapshot: QuotaSnapshot
            do {
                snapshot = try await provider.fetchQuota(account: account, secret: refreshedSecret, intent: intent)
            } catch {
                guard provider.isAuthenticationFailure(error),
                      let forcedSecret = try await provider.refreshSecretAfterAuthenticationFailure(refreshedSecret) else {
                    throw error
                }
                if forcedSecret != refreshedSecret {
                    try await persistRefreshedSecret(
                        forcedSecret,
                        previousSecret: refreshedSecret,
                        account: account,
                        provider: provider
                    )
                    refreshedSecret = forcedSecret
                }
                snapshot = try await provider.fetchQuota(account: account, secret: refreshedSecret, intent: .manual)
            }
            let settingsChanged = updateAccountSettingsIfNeeded(
                accountID: account.id,
                provider: provider,
                secret: refreshedSecret
            )
            let readableNameUpdated = updateAccountReadableNameIfNeeded(
                accountID: account.id,
                provider: provider,
                secret: refreshedSecret
            )
            let renamed = updateAccountIdentityIfNeeded(accountID: account.id, identity: snapshot.accountIdentifier)
            if shouldPreserveExistingClaudeQuota(snapshot, for: account) {
                errorByAccount[account.id] = nil
                errorRequiresUserActionByAccount[account.id] = nil
                loadStateByAccount[account.id] = loadStateAfterFailedRefresh(for: account)
                refreshFailureCountByAccount[account.id] = nil
                refreshBackoffUntilByAccount[account.id] = nil
                if renamed || settingsChanged || readableNameUpdated {
                    try await persistState()
                }
                AppLog.refresh.info("Preserved existing Claude Code quota for account \(account.id.uuidString, privacy: .public) while waiting for statusLine data")
                return
            }
            quotaByAccount[account.id] = snapshot
            errorByAccount[account.id] = nil
            errorRequiresUserActionByAccount[account.id] = nil
            loadStateByAccount[account.id] = .loaded
            refreshFailureCountByAccount[account.id] = nil
            refreshBackoffUntilByAccount[account.id] = nil
            do {
                try quotaCacheStore.save(snapshot, accountID: account.id)
            } catch {
                AppLog.refresh.error("Failed to cache quota snapshot for \(account.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)")
            }
            if renamed || settingsChanged || readableNameUpdated {
                try await persistState()
            }
            AppLog.refresh.info("Refresh succeeded for account \(account.id.uuidString, privacy: .public)")
        } catch {
            let failureCount = (refreshFailureCountByAccount[account.id] ?? 0) + 1
            refreshFailureCountByAccount[account.id] = failureCount
            let retryAt = retryDeadline(for: error)
                ?? Date().addingTimeInterval(refreshBackoffPolicy.delay(afterFailureCount: failureCount))
            if !intent.bypassesAppBackoff {
                refreshBackoffUntilByAccount[account.id] = retryAt
            }
            AppLog.refresh.error("Refresh failed for account \(account.id.uuidString, privacy: .public), failures=\(failureCount, privacy: .public): \(String(describing: error), privacy: .private)")
            errorByAccount[account.id] = text.refreshAccountFailedMessage(resolvedErrorMessage(error))
            errorRequiresUserActionByAccount[account.id] = errorRequiresUserAction(error)
            loadStateByAccount[account.id] = loadStateAfterFailedRefresh(for: account)
        }
    }

    private func shouldPreserveExistingClaudeQuota(_ snapshot: QuotaSnapshot, for account: Account) -> Bool {
        guard account.tool == .claudeCode,
              let existing = quotaByAccount[account.id],
              existing.orderedMetrics.isEmpty == false else {
            return false
        }

        if snapshot.orderedMetrics.isEmpty, snapshot.source == "Claude Code" {
            return true
        }

        if snapshot.source == "Claude Code",
           snapshot.secondary == nil,
           existing.secondary != nil,
           snapshot.effectiveAvailabilityStatus == .sessionRateLimited {
            return true
        }

        return snapshot.source == "Claude Code StatusLine"
            && snapshot.orderedMetrics.isEmpty
            && snapshot.planName == "Claude.ai"
    }

    private func persistState() async throws {
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

    private func persistRefreshedSecret(
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
                  let snapshot = try? quotaCacheStore.load(accountID: account.id, tool: account.tool) else {
                continue
            }
            let cachedSource = snapshot.source.lowercased().contains("cache")
                ? snapshot.source
                : "\(snapshot.source) Cache"
            quotaByAccount[account.id] = snapshot.replacing(source: cachedSource)
            loadStateByAccount[account.id] = loadStateForCachedSnapshot(snapshot)
        }
    }

    private func provider(for tool: ToolKind) -> any Provider {
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

    private func resolveSecret(for account: Account, provider: any Provider) async throws -> String {
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

    private func resolvedErrorMessage(_ error: Error) -> String {
        text.userFacingErrorMessage(error)
    }

    private func retryDeadline(for error: Error) -> Date? {
        if let httpError = error as? QuotaHTTPError,
           let retryAfter = httpError.retryAfter,
           retryAfter > Date() {
            return retryAfter
        }
        if case ProviderError.rateLimited(_, let retryAfter) = error,
           let retryAfter,
           retryAfter > Date() {
            return retryAfter
        }
        return nil
    }

    private func errorRequiresUserAction(_ error: Error) -> Bool {
        if error is SecretStoreError {
            return true
        }
        if let httpError = error as? QuotaHTTPError {
            return httpError.statusCode == 401 || httpError.statusCode == 403
        }
        guard let providerError = error as? ProviderError else {
            return false
        }

        switch providerError {
        case .missingFile,
             .invalidCredentials,
             .credentialParsingFailed,
             .tokenExpired,
             .tokenRefreshFailed,
             .noUsableCredential:
            return true
        case .cacheCorrupted,
             .rateLimited:
            return false
        case .unsupported(let message),
             .network(let message):
            return providerMessageRequiresUserAction(message)
        }
    }

    private func providerMessageRequiresUserAction(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("http 429")
            || lower.contains("http 5")
            || containsAny(message, ["请求过于频繁", "命令超时", "请求超时", "无 HTTP 响应", "查询失败", "刷新失败"]) {
            return false
        }

        return lower.contains("refresh token")
            || containsAny(message, [
                "账号不一致",
                "帳號不一致",
                "凭据与当前账号不一致",
                "返回账号与当前账号不一致",
                "登录已过期",
                "登录已失效",
                "登录续期失败",
                "token 已",
                "token 无效",
                "未找到 Cursor 登录状态",
                "未找到 Cursor 登录 token",
                "未找到登录文件",
                "未找到登录信息",
                "尚未登录",
                "未检测到 Cursor 登录完成",
                "未检测到新的 Cursor 登录凭据",
                "登录未完成",
                "登录超时",
                "浏览器登录超时",
                "设备码登录超时",
                "Agent 登录超时",
                "登录失败",
                "未找到 Codex CLI",
                "未找到 codex 命令",
                "未找到 Claude Code CLI",
                "未找到 claude",
                "未找到命令",
                "Keychain",
                "登录信息异常",
                "本地凭据",
                "登录状态失败",
                "无法创建数据库快照"
            ])
    }

    private func containsAny(_ message: String, _ needles: [String]) -> Bool {
        needles.contains { message.localizedCaseInsensitiveContains($0) }
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

    private func updateAccountIdentityIfNeeded(accountID: UUID, identity: String?) -> Bool {
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

    private func updateAccountReadableNameIfNeeded(
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

    private func updateAccountSettingsIfNeeded(
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
