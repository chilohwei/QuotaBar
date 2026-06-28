import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var activeAccountByTool: [ToolKind: UUID] = [:]
    @Published var selectedTool: ToolKind = .codex
    @Published var quotaByAccount: [UUID: QuotaSnapshot] = [:]
    @Published var errorByAccount: [UUID: String] = [:]
    @Published var loadStateByAccount: [UUID: AccountLoadState] = [:]
    @Published var isAddingAccount = false
    @Published var language: AppLanguage = .stored
    @Published var restartRequiredMessage: String?
    @Published var addAccountErrorMessage: String?
    @Published var updateBannerState: AppUpdateBannerState = .idle
    @Published var isLaunchAtLoginEnabled = false
    @Published var isRefreshOnOpenEnabled: Bool = AppPreferences.refreshOnOpenEnabled
    @Published var recommendationStrategy: AccountRecommendationStrategy = AppPreferences.recommendationStrategy
    @Published var menuBarVisibleTools: Set<ToolKind> = AppPreferences.menuBarVisibleTools

    private let accountStore = AccountStore()
    private let secretStore = SecretStoreService()
    private let quotaCacheStore = QuotaSnapshotCacheStore()
    private let providerRegistry = ProviderRegistry()
    private let refreshBackoffPolicy = RefreshBackoffPolicy()
    private var checkForUpdatesAction: (() -> Void)?
    private var installAvailableUpdateAction: (() -> Void)?
    private var launchAtLoginEnabledProvider: (() -> Bool)?
    private var setLaunchAtLoginEnabledAction: ((Bool) -> Void)?

    private var refreshTask: Task<Void, Never>?
    private var addAccountTask: Task<Void, Never>?
    private var addAccountOperationID: UUID?
    private var refreshingAccountIDs: Set<UUID> = []
    private var refreshFailureCountByAccount: [UUID: Int] = [:]
    private var refreshBackoffUntilByAccount: [UUID: Date] = [:]
    private let maxConcurrentRefreshes = 4
    private let autoRefreshInterval: TimeInterval = 5 * 60
    private let autoRefreshJitter: TimeInterval = 30
    private let foregroundRefreshFreshnessInterval: TimeInterval = 45
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
            await refreshAccounts(initiallySelectedAccounts, forceRefresh: true)

            await syncInstalledCredentialsAtLaunch()
            normalizeActiveSelections()
            await applyActiveSelectionsToInstalledTools()
            await normalizeAccountNamesIfNeeded()

            let selectedAccounts = accounts(for: selectedTool)
            if selectedTool != initialSelectedTool || shouldRefreshForForegroundDisplay(selectedAccounts) {
                primeRefreshState(for: selectedAccounts)
                await refreshAccounts(selectedAccounts, forceRefresh: true)
            }

            loadCachedQuotaSnapshots()
            startAutoRefreshLoop()
            await refreshRemainingAccountsInBackground(excluding: Set(selectedAccounts.map(\.id)))
            AppLog.app.info("App state bootstrap finished")
        }
    }

    func shutdown() {
        refreshTask?.cancel()
        addAccountTask?.cancel()
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
                addAccountErrorMessage = "添加账号失败: \(resolvedErrorMessage(error))"
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
                errorByAccount[account.id] = "删除失败: \(resolvedErrorMessage(error))"
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
                let syncedAccount = await syncInstalledCurrentAccount(for: account.tool)
                restartRequiredMessage = text.restartRequiredMessage(accountName: account.name)
                await refreshQuota(for: syncedAccount ?? account, forceRefresh: true)
            } catch {
                AppLog.account.error("Activate account failed for \(account.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)")
                errorByAccount[account.id] = "切换失败: \(resolvedErrorMessage(error))"
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
            await refreshAccounts(targetAccounts, forceRefresh: true)
        }
    }

    func prepareSelectedToolForDashboardPresentation() async {
        let tool = selectedTool
        await syncInstalledCurrentAccount(for: tool)
        guard isRefreshOnOpenEnabled else { return }

        let targetAccounts = accounts(for: tool)
        guard !targetAccounts.isEmpty else { return }
        guard targetAccounts.contains(where: { quotaByAccount[$0.id] == nil }) else { return }

        primeRefreshState(for: targetAccounts)
        await refreshAccounts(targetAccounts, forceRefresh: true)
    }

    func refreshAccount(_ account: Account) {
        primeRefreshState(for: [account])
        Task {
            await syncInstalledCurrentAccount(for: account.tool)
            let target = accounts.first(where: { $0.id == account.id }) ?? account
            primeRefreshState(for: [target])
            await refreshQuota(for: target, forceRefresh: true)
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
            await refreshAccounts(targetAccounts, forceRefresh: true)
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
        AppPreferences.setRefreshOnOpenEnabled(enabled)
    }

    func setRecommendationStrategy(_ strategy: AccountRecommendationStrategy) {
        guard recommendationStrategy != strategy else { return }
        recommendationStrategy = strategy
        AppPreferences.setRecommendationStrategy(strategy)
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
        AppPreferences.setMenuBarVisibleTools(menuBarVisibleTools)
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
        let detectedName = provider.suggestAccountName(from: secret) ?? extractEmail(from: secret)
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
                let shouldRename = looksAutoGeneratedName(accounts[index].name, tool: tool)
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
                await refreshQuota(for: syncedDuplicate)
            }
            return syncedDuplicate
        }

        let resolvedName = resolvedAccountName(
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
            await refreshQuota(for: account)
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
                let delay = autoRefreshInterval + Double.random(in: 0 ... autoRefreshJitter)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await refreshActiveAccounts()
            }
        }
    }

    private func refreshActiveAccounts() async {
        await syncInstalledCurrentAccounts()
        await refreshAccounts(supportedToolsPrioritizingSelectedTool.compactMap { activeAccount(for: $0) })
    }

    private func refreshRemainingAccountsInBackground(excluding refreshedAccountIDs: Set<UUID>) async {
        let remainingAccounts = accounts.filter { account in
            supportedTools.contains(account.tool) && !refreshedAccountIDs.contains(account.id)
        }
        guard !remainingAccounts.isEmpty else { return }
        await refreshAccounts(remainingAccounts)
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
            errorByAccount[account.id] = "切换失败: \(resolvedErrorMessage(error))"
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

    private func refreshAccounts(_ targetAccounts: [Account], forceRefresh: Bool = false) async {
        guard !targetAccounts.isEmpty else { return }

        var startIndex = targetAccounts.startIndex
        while startIndex < targetAccounts.endIndex {
            let endIndex = targetAccounts.index(startIndex, offsetBy: maxConcurrentRefreshes, limitedBy: targetAccounts.endIndex)
                ?? targetAccounts.endIndex
            let batch = Array(targetAccounts[startIndex ..< endIndex])

            await withTaskGroup(of: Void.self) { group in
                for account in batch {
                    group.addTask { [weak self] in
                        await self?.refreshQuota(for: account, forceRefresh: forceRefresh)
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
        targetAccounts.contains { account in
            guard supportedTools.contains(account.tool) else { return false }
            if refreshingAccountIDs.contains(account.id) {
                return false
            }

            switch loadStateByAccount[account.id] {
            case .loadingInitial, .refreshing:
                return false
            case .failed, .stale:
                return true
            case .idle, .none:
                return quotaByAccount[account.id] == nil
            case .loaded:
                guard let snapshot = quotaByAccount[account.id] else { return true }
                return Date().timeIntervalSince(snapshot.updatedAt) > foregroundRefreshFreshnessInterval
            }
        }
    }

    private func refreshQuota(for account: Account, forceRefresh: Bool = false) async {
        guard !refreshingAccountIDs.contains(account.id) else { return }
        if forceRefresh {
            refreshBackoffUntilByAccount[account.id] = nil
        } else if let retryAt = refreshBackoffUntilByAccount[account.id], retryAt > Date() {
            AppLog.refresh.debug("Skipping account \(account.id.uuidString, privacy: .public) until \(retryAt, privacy: .public)")
            return
        }
        let provider = provider(for: account.tool)
        let hadSnapshot = quotaByAccount[account.id] != nil

        AppLog.refresh.info("Refreshing account \(account.id.uuidString, privacy: .public) for \(account.tool.rawValue, privacy: .public), force=\(forceRefresh, privacy: .public)")
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
                snapshot = try await provider.fetchQuota(account: account, secret: refreshedSecret, forceRefresh: forceRefresh)
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
                snapshot = try await provider.fetchQuota(account: account, secret: refreshedSecret, forceRefresh: true)
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
                loadStateByAccount[account.id] = .stale
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
            let retryAt = Date().addingTimeInterval(refreshBackoffPolicy.delay(afterFailureCount: failureCount))
            if !forceRefresh {
                refreshBackoffUntilByAccount[account.id] = retryAt
            }
            AppLog.refresh.error("Refresh failed for account \(account.id.uuidString, privacy: .public), failures=\(failureCount, privacy: .public): \(String(describing: error), privacy: .private)")
            errorByAccount[account.id] = "刷新失败: \(resolvedErrorMessage(error))"
            loadStateByAccount[account.id] = quotaByAccount[account.id] == nil ? .failed : .stale
        }
    }

    private func shouldPreserveExistingClaudeQuota(_ snapshot: QuotaSnapshot, for account: Account) -> Bool {
        guard account.tool == .claudeCode,
              snapshot.orderedMetrics.isEmpty,
              quotaByAccount[account.id]?.orderedMetrics.isEmpty == false else {
            return false
        }

        if snapshot.source == "Claude Code" {
            return true
        }

        return snapshot.source == "Claude Code StatusLine"
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
                  let snapshot = try? quotaCacheStore.load(accountID: account.id) else {
                continue
            }
            let cachedSource = snapshot.source.lowercased().contains("cache")
                ? snapshot.source
                : "\(snapshot.source) Cache"
            quotaByAccount[account.id] = snapshot.replacing(source: cachedSource)
            loadStateByAccount[account.id] = .stale
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
            guard looksAutoGeneratedName(account.name, tool: account.tool) else { continue }
            let provider = provider(for: account.tool)
            guard let secret = try? await resolveSecret(for: account, provider: provider) else { continue }

            if let identity = provider.accountIdentity(from: secret)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !identity.isEmpty,
               accounts[index].settings.identityKey != identity {
                accounts[index].settings.identityKey = identity
                didChange = true
            }

            guard let readable = provider.suggestAccountName(from: secret) ?? extractEmail(from: secret) else { continue }

            if accounts[index].name != readable {
                accounts[index].name = readable
                didChange = true
            }
        }

        if didChange {
            try? await persistState()
        }
    }

    private func resolvedAccountName(
        tool: ToolKind,
        provider: any Provider,
        inputName: String,
        secret: String
    ) -> String {
        let detectedName = provider.suggestAccountName(from: secret) ?? extractEmail(from: secret)
        if let detectedName,
           inputName.isEmpty || looksAutoGeneratedName(inputName, tool: tool) {
            return detectedName
        }

        if !inputName.isEmpty {
            return inputName
        }

        return "\(tool.displayName) 账号"
    }

    private func looksAutoGeneratedName(_ name: String, tool: ToolKind) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lower = trimmed.lowercased()
        let prefix = tool.displayName.lowercased()
        if tool == .claudeCode,
           lower.range(of: #"^claude [0-9a-f]{8}$"#, options: .regularExpression) != nil {
            return true
        }
        if lower == prefix || lower == "\(prefix)账号" || lower.hasPrefix("\(prefix)-") {
            return true
        }

        if trimmed.contains(":"), trimmed.rangeOfCharacter(from: .decimalDigits) != nil, lower.hasPrefix(prefix) {
            return true
        }

        return false
    }

    private func extractEmail(from text: String) -> String? {
        let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        return String(text[matchRange]).lowercased()
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
        if let urlError = error as? URLError {
            switch urlError.code {
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired,
                 .appTransportSecurityRequiresSecureConnection:
                return "网络 SSL 握手失败，请检查代理/VPN/系统证书后重试"
            case .notConnectedToInternet:
                return "当前网络不可用，请检查网络后重试"
            case .timedOut:
                return "请求超时，请稍后重试"
            default:
                break
            }
        }

        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        return error.localizedDescription
    }

    private func findDuplicateStoredAccount(
        for tool: ToolKind,
        detectedIdentities: [String]
    ) -> Account? {
        let normalizedDetectedIdentities = Set(detectedIdentities.map(normalizeIdentityName))
        guard !normalizedDetectedIdentities.isEmpty else { return nil }

        for account in accounts where account.tool == tool {
            if let storedIdentity = account.settings.identityKey.map(normalizeIdentityName),
               normalizedDetectedIdentities.contains(storedIdentity) {
                return account
            }
        }

        return nil
    }

    private func normalizeIdentityName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func updateAccountIdentityIfNeeded(accountID: UUID, identity: String?) -> Bool {
        guard let identity = identity?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return false
        }

        let current = accounts[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != identity else { return false }

        let shouldPreferIdentity = looksAutoGeneratedName(current, tool: accounts[index].tool)
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
        guard looksAutoGeneratedName(current, tool: accounts[index].tool) || current.isEmpty else {
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

private enum AppPreferences {
    private static let refreshOnOpenKey = "QuotaBar.RefreshOnOpenEnabled"
    private static let recommendationStrategyKey = "QuotaBar.RecommendationStrategy"
    private static let menuBarVisibleToolsKey = "QuotaBar.MenuBarVisibleTools"

    static var refreshOnOpenEnabled: Bool {
        bool(forKey: refreshOnOpenKey, defaultValue: true)
    }

    static var menuBarVisibleTools: Set<ToolKind> {
        // Absent key (first launch) means show everything; an explicitly empty
        // saved array is honored as "show none".
        guard let raw = UserDefaults.standard.array(forKey: menuBarVisibleToolsKey) as? [String] else {
            return Set(ToolKind.allCases)
        }
        return Set(raw.compactMap(ToolKind.init(rawValue:)))
    }

    static func setMenuBarVisibleTools(_ tools: Set<ToolKind>) {
        UserDefaults.standard.set(tools.map(\.rawValue), forKey: menuBarVisibleToolsKey)
    }

    static var recommendationStrategy: AccountRecommendationStrategy {
        guard let rawValue = UserDefaults.standard.string(forKey: recommendationStrategyKey),
              let strategy = AccountRecommendationStrategy(rawValue: rawValue) else {
            return .preventWaste
        }
        return strategy
    }

    static func setRefreshOnOpenEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: refreshOnOpenKey)
    }

    static func setRecommendationStrategy(_ strategy: AccountRecommendationStrategy) {
        UserDefaults.standard.set(strategy.rawValue, forKey: recommendationStrategyKey)
    }

    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}
