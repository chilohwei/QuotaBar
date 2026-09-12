import Foundation

extension AppState {
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

    func finalizePendingDeletionNow() {
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
}
