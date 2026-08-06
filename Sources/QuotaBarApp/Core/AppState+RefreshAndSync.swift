import CryptoKit
import Foundation

// Refresh scheduling, quota fetching, and installed-tool credential sync.
extension AppState {
    func startAutoRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                let delay = automaticRefreshInterval() + Double.random(in: 0 ... autoRefreshJitter)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                // Gate the periodic tick on freshness so it skips accounts a foreground / dashboard /
                // wake refresh just fetched, instead of re-hitting Codex/Cursor over the network every
                // cycle. The interval equals the (quota-adaptive) sleep interval, so an account's own
                // scheduled refresh — one full interval old — still fires on cadence.
                await refreshActiveAccountsIfNeeded(
                    freshnessInterval: automaticRefreshInterval(),
                    intent: .background
                )
            }
        }
    }

    func refreshActiveAccounts(intent: RefreshIntent = .background) async {
        await syncInstalledCurrentAccounts()
        await refreshAccounts(
            supportedToolsPrioritizingSelectedTool.compactMap { activeAccount(for: $0) },
            intent: intent
        )
    }

    func refreshActiveAccountsIfNeeded(freshnessInterval: TimeInterval, intent: RefreshIntent) async {
        await syncInstalledCurrentAccounts()
        let targetAccounts = supportedToolsPrioritizingSelectedTool
            .compactMap { activeAccount(for: $0) }
            .filter { shouldRefreshAccount($0, freshnessInterval: freshnessInterval) }
        await refreshAccounts(targetAccounts, intent: intent)
    }

    func refreshActiveAccount(for tool: ToolKind, syncInstalled: Bool, intent: RefreshIntent) async {
        if syncInstalled {
            await syncInstalledCurrentAccount(for: tool, intent: intent)
        }
        guard let account = activeAccount(for: tool) else { return }
        await refreshQuota(for: account, intent: intent)
    }

    func startDashboardRefreshLoop() {
        dashboardRefreshTask?.cancel()
        dashboardRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(dashboardVisibleRefreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await refreshDashboardVisibleAccountsIfNeeded()
            }
        }
    }

    func refreshDashboardVisibleAccountsIfNeeded() async {
        guard isDashboardVisible else { return }
        let targetAccounts = dashboardVisibleAccounts()
            .filter { shouldRefreshAccount($0, freshnessInterval: dashboardVisibleRefreshInterval) }
        guard !targetAccounts.isEmpty else { return }

        await syncInstalledCurrentAccount(for: selectedTool)
        primeRefreshState(for: targetAccounts)
        await refreshAccounts(targetAccounts, intent: .visible)
    }

    func dashboardVisibleAccounts() -> [Account] {
        let selectedAccounts = accounts(for: selectedTool)
        guard !dashboardVisibleAccountIDs.isEmpty else {
            return selectedAccounts
        }
        let visibleIDs = Set(dashboardVisibleAccountIDs)
        return selectedAccounts.filter { visibleIDs.contains($0.id) }
    }

    func automaticRefreshInterval() -> TimeInterval {
        let activeRemainingRatios = supportedTools.compactMap { activeAccount(for: $0) }
            .compactMap { quotaByAccount[$0.id]?.statusBarMetric?.ratio }
        return refreshIntervalPolicy.automaticRefreshInterval(activeRemainingRatios: activeRemainingRatios)
    }

    func startRefreshEventMonitor() {
        let monitor = RefreshEventMonitor { [weak self] reason in
            self?.handleRefreshEvent(reason)
        }
        refreshEventMonitor?.stop()
        refreshEventMonitor = monitor
        monitor.start(watchTargets: RefreshWatchTargetFactory().watchTargets())
    }

    func handleRefreshEvent(_ reason: RefreshEventReason) {
        refreshEventTasks[reason]?.cancel()
        refreshEventTasks[reason] = Task { [weak self] in
            await self?.performRefreshEvent(reason)
            await MainActor.run {
                self?.refreshEventTasks[reason] = nil
            }
        }
    }

    func performRefreshEvent(_ reason: RefreshEventReason) async {
        guard !Task.isCancelled else { return }
        switch reason {
        case .claudeStatusLineChanged:
            // Claude rotates a single-use refresh-token pair while serving CLI requests.
            // Capture that pair before the next account switch overwrites the shared keychain.
            await refreshActiveAccount(for: .claudeCode, syncInstalled: true, intent: .local)
        case .credentialsChanged(let tool):
            await refreshAfterCredentialChange(for: tool)
        case .usageMayHaveChanged(let tool):
            await refreshOnUsageSignal(for: tool)
        case .appForegrounded:
            await refreshActiveAccountsIfNeeded(freshnessInterval: foregroundRefreshFreshnessInterval, intent: .visible)
        case .systemWoke, .networkRestored:
            await refreshActiveAccounts(intent: .visible)
        }
    }

    /// True when a usage-activity signal for `tool` should trigger a live refresh now, given the
    /// per-tool coalescing throttle. Pure and injectable for testing.
    func shouldAcceptUsageSignal(for tool: ToolKind, now: Date = Date()) -> Bool {
        guard supportedTools.contains(tool) else { return false }
        if let last = lastUsageRefreshByTool[tool],
           now.timeIntervalSince(last) < usageSignalMinRefreshInterval {
            return false
        }
        return true
    }

    /// The user is actively using `tool` (its local activity file changed), so its server-side quota
    /// may have moved — fetch a fresh snapshot, throttled to keep the menu bar near-real-time without
    /// hammering the API. Credentials are not re-synced here; that is the credentials-changed path.
    func refreshOnUsageSignal(for tool: ToolKind) async {
        let now = Date()
        guard shouldAcceptUsageSignal(for: tool, now: now) else { return }
        lastUsageRefreshByTool[tool] = now
        await refreshActiveAccount(for: tool, syncInstalled: false, intent: .visible)
    }

    /// The instant to fire a reset-boundary refresh for `snapshot`: just after its earliest future
    /// window reset, or nil when no window resets in the future. Pure and injectable for testing.
    func nextResetBoundaryRefreshDate(for snapshot: QuotaSnapshot, now: Date = Date()) -> Date? {
        let futureResets = snapshot.orderedMetrics
            .compactMap { $0.resetAt }
            .filter { $0 > now }
        guard let nextReset = futureResets.min() else { return nil }
        return nextReset.addingTimeInterval(resetBoundaryRefreshLeeway)
    }

    /// Schedule a one-shot refresh just after the account's nearest window reset so the recovered
    /// quota shows immediately instead of waiting for the next periodic tick. Replaces any reset
    /// refresh already scheduled for the account.
    func scheduleResetBoundaryRefresh(for account: Account) {
        let accountID = account.id
        resetRefreshTasks[accountID]?.cancel()
        resetRefreshTasks[accountID] = nil
        guard let snapshot = quotaByAccount[accountID],
              let fireDate = nextResetBoundaryRefreshDate(for: snapshot) else {
            return
        }
        let delay = max(fireDate.timeIntervalSinceNow, 0)
        resetRefreshTasks[accountID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Clear our own slot before refreshing so the refresh's re-schedule cannot cancel us.
            await MainActor.run { self?.resetRefreshTasks[accountID] = nil }
            await self?.refreshQuota(for: account, intent: .visible)
        }
    }

    func refreshAfterCredentialChange(for tool: ToolKind) async {
        guard supportedTools.contains(tool) else { return }
        guard await beginCredentialSync(for: tool) else { return }
        defer { finishCredentialSync(for: tool) }
        let provider = provider(for: tool)

        do {
            var secret = try await provider.importCurrentCredentials()
            guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            if absorbCredentialSyncForPendingDeletion(
                tool: tool,
                provider: provider,
                secret: secret
            ) {
                credentialSignatureByTool[tool] = credentialEventSignature(secret: secret, provider: provider)
                AppLog.refresh.info("Skipped credential event for pending-deletion \(tool.rawValue, privacy: .public) account")
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

    func refreshRemainingAccountsInBackground(excluding refreshedAccountIDs: Set<UUID>) async {
        let remainingAccounts = accounts.filter { account in
            supportedTools.contains(account.tool) && !refreshedAccountIDs.contains(account.id)
        }
        guard !remainingAccounts.isEmpty else { return }
        await refreshAccounts(remainingAccounts, intent: .background)
    }

    func applyActiveSelectionsToInstalledTools() async {
        for tool in supportedToolsPrioritizingSelectedTool {
            await applyActiveSelectionToInstalledTool(tool)
        }
    }

    func applyActiveSelectionToInstalledTool(
        _ tool: ToolKind,
        discardedAccount: Account? = nil
    ) async {
        guard let account = activeAccount(for: tool) else { return }
        let provider = provider(for: tool)
        do {
            if tool == .claudeCode {
                try await performAccountActivation(
                    account,
                    captureMissingCurrentAccount: false,
                    discardedAccount: discardedAccount
                )
            } else {
                let secret = try await resolveSecret(for: account, provider: provider)
                try await provider.activate(account: account, secret: secret)
            }
        } catch {
            AppLog.account.error("Apply active selection failed for \(account.id.uuidString, privacy: .public): \(String(describing: error), privacy: .private)")
            errorByAccount[account.id] = text.switchAccountFailedMessage(resolvedErrorMessage(error))
            errorRequiresUserActionByAccount[account.id] = errorRequiresUserAction(error)
            loadStateByAccount[account.id] = quotaByAccount[account.id] == nil ? .failed : .stale
        }
    }

    func syncInstalledCredentialsAtLaunch() async {
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

    func syncInstalledCurrentAccounts() async {
        for tool in supportedToolsPrioritizingSelectedTool {
            await syncInstalledCurrentAccount(for: tool)
        }
    }

    @discardableResult
    func syncInstalledCurrentAccount(
        for tool: ToolKind,
        intent: RefreshIntent = .background
    ) async -> Account? {
        guard supportedTools.contains(tool) else { return nil }
        guard await beginCredentialSync(for: tool) else { return nil }
        defer { finishCredentialSync(for: tool) }
        let provider = provider(for: tool)

        do {
            var secret = try await provider.importCurrentCredentials()
            guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            if absorbCredentialSyncForPendingDeletion(
                tool: tool,
                provider: provider,
                secret: secret
            ) {
                credentialSignatureByTool[tool] = credentialEventSignature(secret: secret, provider: provider)
                AppLog.account.info("Skipped credential sync for pending-deletion \(tool.rawValue, privacy: .public) account")
                return nil
            }
            if intent.allowsProviderCredentialRefresh,
               let refreshed = try? await provider.refreshSecretIfNeeded(secret) {
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

    func credentialEventSignature(secret: String, provider: any Provider) -> String {
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

    /// Claude's credential files and keychain describe one process-global account. Keep imports
    /// outside the replacement transaction so a late file event cannot reactivate the old account
    /// after the new keychain pair has been installed.
    func beginCredentialSync(for tool: ToolKind) async -> Bool {
        guard tool == .claudeCode else { return true }
        while activatingTools.contains(tool) || (credentialSyncCountByTool[tool] ?? 0) > 0 {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        credentialSyncCountByTool[tool, default: 0] += 1
        return true
    }

    func finishCredentialSync(for tool: ToolKind) {
        guard tool == .claudeCode,
              let count = credentialSyncCountByTool[tool] else { return }
        if count <= 1 {
            credentialSyncCountByTool.removeValue(forKey: tool)
        } else {
            credentialSyncCountByTool[tool] = count - 1
        }
    }

    func refreshAccounts(_ targetAccounts: [Account], intent: RefreshIntent = .background) async {
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

    func primeRefreshState(for targetAccounts: [Account]) {
        for account in targetAccounts where supportedTools.contains(account.tool) {
            guard !refreshingAccountIDs.contains(account.id),
                  !activatingTools.contains(account.tool) else { continue }
            loadStateByAccount[account.id] = quotaByAccount[account.id] == nil ? .loadingInitial : .refreshing
        }
    }

    func shouldRefreshForForegroundDisplay(_ targetAccounts: [Account]) -> Bool {
        shouldRefreshAccounts(targetAccounts, freshnessInterval: foregroundRefreshFreshnessInterval)
    }

    func shouldRefreshAccounts(_ targetAccounts: [Account], freshnessInterval: TimeInterval) -> Bool {
        targetAccounts.contains { shouldRefreshAccount($0, freshnessInterval: freshnessInterval) }
    }

    func shouldRefreshAccount(_ account: Account, freshnessInterval: TimeInterval) -> Bool {
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

    func effectiveFreshnessInterval(for account: Account, default freshnessInterval: TimeInterval) -> TimeInterval {
        guard account.tool == .claudeCode,
              let snapshot = quotaByAccount[account.id],
              QuotaFreshness.isStale(snapshot) else {
            return freshnessInterval
        }
        return min(freshnessInterval, 30)
    }

    func loadStateAfterFailedRefresh(for account: Account) -> AccountLoadState {
        guard let snapshot = quotaByAccount[account.id] else {
            return .failed
        }
        return QuotaFreshness.isStale(snapshot) ? .stale : .loaded
    }

    func loadStateForCachedSnapshot(_ snapshot: QuotaSnapshot) -> AccountLoadState {
        QuotaFreshness.isStale(snapshot) ? .stale : .loaded
    }

    func refreshQuota(for account: Account, intent: RefreshIntent = .background) async {
        guard !refreshingAccountIDs.contains(account.id) else { return }
        guard !activatingTools.contains(account.tool) else {
            restoreRefreshStateAfterSkippedRefresh(for: account)
            return
        }
        if intent == .manual {
            refreshBackoffUntilByAccount[account.id] = nil
        } else if !intent.bypassesAppBackoff,
                  let retryAt = refreshBackoffUntilByAccount[account.id],
                  retryAt > Date() {
            AppLog.refresh.debug("Skipping account \(account.id.uuidString, privacy: .public) until \(retryAt, privacy: .public)")
            return
        }
        let provider = provider(for: account.tool)
        let hadSnapshot = quotaByAccount[account.id] != nil

        AppLog.refresh.info("Refreshing account \(account.id.uuidString, privacy: .public) for \(account.tool.rawValue, privacy: .public), intent=\(intent.rawValue, privacy: .public)")
        refreshingAccountIDs.insert(account.id)
        refreshingToolByAccountID[account.id] = account.tool
        loadStateByAccount[account.id] = hadSnapshot ? .refreshing : .loadingInitial
        defer {
            refreshingAccountIDs.remove(account.id)
            refreshingToolByAccountID.removeValue(forKey: account.id)
            if loadStateByAccount[account.id] == .refreshing || loadStateByAccount[account.id] == .loadingInitial {
                loadStateByAccount[account.id] = quotaByAccount[account.id] == nil ? .idle : .loaded
            }
        }

        do {
            let resolvedSecret = try await resolveSecret(for: account, provider: provider)
            let storedSecretAtStart = account.tool == .claudeCode
                ? storedSecretSnapshot(for: account)
                : nil
            let secret = if let storedSecretAtStart {
                (try? provider.reconcileImportedSecret(
                    resolvedSecret,
                    withStoredSecret: storedSecretAtStart
                )) ?? resolvedSecret
            } else {
                resolvedSecret
            }
            var refreshedSecret = intent.allowsProviderCredentialRefresh
                ? try await provider.refreshSecretIfNeeded(secret)
                : secret
            if refreshedSecret != secret
                || (account.tool == .claudeCode
                    && storedSecretAtStart != nil
                    && refreshedSecret != storedSecretAtStart) {
                refreshedSecret = try await persistRefreshedSecret(
                    refreshedSecret,
                    previousSecret: secret,
                    expectedStoredSecret: storedSecretAtStart,
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
                    refreshedSecret = try await persistRefreshedSecret(
                        forcedSecret,
                        previousSecret: refreshedSecret,
                        expectedStoredSecret: account.tool == .claudeCode
                            ? storedSecretSnapshot(for: account)
                            : nil,
                        account: account,
                        provider: provider
                    )
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
                // Keep the last real metrics, but drop windows whose reset has passed
                // and let the incoming snapshot's note/availability through — that is
                // where "refresh is rate-limited" guidance travels.
                if let existing = quotaByAccount[account.id] {
                    quotaByAccount[account.id] = existing
                        .removingExpiredWindows()
                        .replacing(
                            note: snapshot.note,
                            availabilityStatus: snapshot.availabilityStatus
                        )
                }
                errorByAccount[account.id] = nil
                errorRequiresUserActionByAccount[account.id] = nil
                loadStateByAccount[account.id] = loadStateAfterFailedRefresh(for: account)
                refreshFailureCountByAccount[account.id] = nil
                if !intent.preservesAppBackoffAfterSuccess {
                    refreshBackoffUntilByAccount[account.id] = nil
                }
                if renamed || settingsChanged || readableNameUpdated {
                    try await persistState()
                }
                scheduleResetBoundaryRefresh(for: account)
                AppLog.refresh.info("Preserved existing Claude Code quota for account \(account.id.uuidString, privacy: .public) while waiting for statusLine data")
                return
            }
            evaluateQuotaNotifications(for: account, previous: quotaByAccount[account.id], current: snapshot)
            quotaByAccount[account.id] = snapshot
            scheduleResetBoundaryRefresh(for: account)
            errorByAccount[account.id] = nil
            errorRequiresUserActionByAccount[account.id] = nil
            loadStateByAccount[account.id] = .loaded
            refreshFailureCountByAccount[account.id] = nil
            if !intent.preservesAppBackoffAfterSuccess {
                refreshBackoffUntilByAccount[account.id] = nil
            }
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

    func restoreRefreshStateAfterSkippedRefresh(for account: Account) {
        guard loadStateByAccount[account.id] == .refreshing
            || loadStateByAccount[account.id] == .loadingInitial else {
            return
        }
        if errorByAccount[account.id] != nil {
            loadStateByAccount[account.id] = quotaByAccount[account.id] == nil ? .failed : .stale
        } else if let snapshot = quotaByAccount[account.id] {
            loadStateByAccount[account.id] = loadStateForCachedSnapshot(snapshot)
        } else {
            loadStateByAccount[account.id] = .idle
        }
    }

    func evaluateQuotaNotifications(for account: Account, previous: QuotaSnapshot?, current: QuotaSnapshot) {
        guard isQuotaNotificationsEnabled else { return }
        guard let event = QuotaNotificationEvaluator.event(
            previousRatio: previous?.statusBarMetric?.ratio,
            currentRatio: current.statusBarMetric?.ratio,
            threshold: quotaNotificationThreshold
        ) else { return }

        switch event {
        case .quotaLow(let remainingPercent):
            notificationService.post(
                identifier: "quota-low-\(account.id.uuidString)",
                title: text.quotaLowNotificationTitle(tool: account.tool),
                body: text.quotaLowNotificationBody(accountName: account.name, remainingPercent: remainingPercent)
            )
        case .quotaExhausted:
            notificationService.post(
                identifier: "quota-exhausted-\(account.id.uuidString)",
                title: text.quotaExhaustedNotificationTitle(tool: account.tool),
                body: text.quotaExhaustedNotificationBody(accountName: account.name)
            )
        case .quotaRecovered(let remainingPercent):
            notificationService.post(
                identifier: "quota-recovered-\(account.id.uuidString)",
                title: text.quotaRecoveredNotificationTitle(tool: account.tool),
                body: text.quotaRecoveredNotificationBody(accountName: account.name, remainingPercent: remainingPercent)
            )
        }
    }

    func shouldPreserveExistingClaudeQuota(_ snapshot: QuotaSnapshot, for account: Account) -> Bool {
        // Judge the existing snapshot by what would survive expiry pruning: metrics
        // whose windows have all reset are stale noise, not worth preserving.
        guard account.tool == .claudeCode,
              let existing = quotaByAccount[account.id]?.removingExpiredWindows(),
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

}
