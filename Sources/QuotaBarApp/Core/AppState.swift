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

    let accountStore = AccountStore()
    let secretStore: SecretStoreService
    let quotaCacheStore = QuotaSnapshotCacheStore()
    let providerRegistry: ProviderRegistry
    let refreshBackoffPolicy = RefreshBackoffPolicy()
    let refreshIntervalPolicy = RefreshIntervalPolicy()
    let notificationService = QuotaNotificationService()
    var hostActions = AppHostActions()

    var refreshTask: Task<Void, Never>?
    var dashboardRefreshTask: Task<Void, Never>?
    var addAccountTask: Task<Void, Never>?
    var addAccountOperationID: UUID?
    var transientNoticeTask: Task<Void, Never>?
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
}
