import Foundation
import Testing
@testable import QuotaBarApp

@Suite("AppState refresh synchronization")
struct AppStateRefreshSynchronizationTests {
    @MainActor
    @Test("Claude credential sync is blocked during account replacement")
    func claudeCredentialSyncIsBlockedDuringReplacement() async {
        let state = AppState()

        #expect(await state.beginCredentialSync(for: .claudeCode))
        #expect(state.credentialSyncCountByTool[.claudeCode] == 1)
        state.finishCredentialSync(for: .claudeCode)

        state.activatingTools.insert(.claudeCode)
        let waitingSync = Task { await state.beginCredentialSync(for: .claudeCode) }
        await Task.yield()
        #expect(state.credentialSyncCountByTool[.claudeCode] == nil)
        waitingSync.cancel()
        #expect(!(await waitingSync.value))
    }

    @MainActor
    @Test("A skipped refresh cannot leave Claude stuck in refreshing state")
    func skippedRefreshRestoresLoadState() async {
        let state = AppState()
        let account = Account(tool: .claudeCode, name: "Claude")
        state.accounts = [account]
        state.loadStateByAccount[account.id] = .loadingInitial
        state.activatingTools.insert(.claudeCode)

        await state.refreshQuota(for: account, intent: .visible)

        #expect(state.loadStateByAccount[account.id] == .idle)
    }

    @MainActor
    @Test("Priming ignores tools while their account replacement is active")
    func primingIgnoresActivatingTool() {
        let state = AppState()
        let account = Account(tool: .claudeCode, name: "Claude")
        state.accounts = [account]
        state.activatingTools.insert(.claudeCode)

        state.primeRefreshState(for: [account])

        #expect(state.loadStateByAccount[account.id] == nil)
    }

    @MainActor
    @Test("the freshness gate follows each provider's own live-fetch floor")
    func freshnessGateFollowsProviderFloor() {
        let state = AppState()
        let claude = Account(tool: .claudeCode, name: "Claude")
        let codex = Account(tool: .codex, name: "Codex")
        state.accounts = [claude, codex]

        // Claude's `/usage` cache floor is 180s, so a 150s background tick would only have been
        // answered from that cache — the gate now waits for the floor instead of burning the tick.
        #expect(state.effectiveFreshnessInterval(for: claude, default: 150) == 180)
        // Opening the panel shortens the floor rather than removing it.
        #expect(state.effectiveFreshnessInterval(for: claude, default: 25, intent: .dashboardOpen) == 60)
        // Providers that always go to the network keep the caller's interval, panel open included.
        #expect(state.effectiveFreshnessInterval(for: codex, default: 150) == 150)
        #expect(state.effectiveFreshnessInterval(for: codex, default: 25, intent: .dashboardOpen) == 25)
    }

    @MainActor
    @Test("stale Claude data still recovers faster than the provider floor")
    func staleClaudeDataBypassesProviderFloor() {
        let state = AppState()
        let claude = Account(tool: .claudeCode, name: "Claude")
        state.accounts = [claude]
        state.quotaByAccount[claude.id] = QuotaSnapshot(
            source: "Claude Code OAuth Cache",
            primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSinceNow: -QuotaFreshness.staleWarningAge - 60),
            note: nil
        )

        #expect(state.effectiveFreshnessInterval(for: claude, default: 150) == 30)
    }

    @MainActor
    @Test("the freshness gate skips a just-loaded account and refreshes a stale one")
    func freshnessGateSkipsFreshRefreshesStale() {
        let state = AppState()
        let account = Account(tool: .codex, name: "Codex")
        state.accounts = [account]

        func snapshot(ageSeconds: TimeInterval) -> QuotaSnapshot {
            QuotaSnapshot(
                source: "Test",
                primary: QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: nil),
                secondary: nil,
                creditsRemaining: nil,
                creditsTotal: nil,
                updatedAt: Date(timeIntervalSinceNow: -ageSeconds),
                note: nil
            )
        }

        // Just loaded → within the freshness window → the periodic tick skips it (no redundant fetch).
        state.quotaByAccount[account.id] = snapshot(ageSeconds: 0)
        state.loadStateByAccount[account.id] = .loaded
        #expect(state.shouldRefreshAccount(account, freshnessInterval: 150) == false)

        // Older than the window → refreshed on cadence.
        state.quotaByAccount[account.id] = snapshot(ageSeconds: 200)
        state.loadStateByAccount[account.id] = .loaded
        #expect(state.shouldRefreshAccount(account, freshnessInterval: 150) == true)

        // A refresh already in flight is never re-entered.
        state.refreshingAccountIDs.insert(account.id)
        #expect(state.shouldRefreshAccount(account, freshnessInterval: 150) == false)
        state.refreshingAccountIDs.remove(account.id)

        // No snapshot yet → always refresh.
        state.quotaByAccount[account.id] = nil
        state.loadStateByAccount[account.id] = .idle
        #expect(state.shouldRefreshAccount(account, freshnessInterval: 150) == true)
    }

    @MainActor
    @Test("usage-triggered refresh is coalesced per tool")
    func usageSignalThrottlePerTool() {
        let state = AppState()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // First activity signal is accepted; record it as the periodic path would.
        #expect(state.shouldAcceptUsageSignal(for: .cursor, now: t0))
        state.lastUsageRefreshByTool[.cursor] = t0

        // A burst of further signals within the window is coalesced away.
        #expect(state.shouldAcceptUsageSignal(for: .cursor, now: t0.addingTimeInterval(5)) == false)
        // After the interval, the next signal is accepted again.
        #expect(state.shouldAcceptUsageSignal(for: .cursor, now: t0.addingTimeInterval(11)))
        // The throttle is per-tool: Codex activity is independent of Cursor's.
        #expect(state.shouldAcceptUsageSignal(for: .codex, now: t0.addingTimeInterval(5)))
    }

    @MainActor
    @Test("reset-boundary refresh schedules just after the nearest future window reset")
    func resetBoundaryRefreshDate() {
        let state = AppState()
        let now = Date(timeIntervalSince1970: 1_000_000)

        // Two windows: the sooner reset (5h) drives the schedule, plus the leeway.
        let snapshot = QuotaSnapshot(
            source: "Test",
            primary: QuotaWindow(label: "5h", used: 50, limit: 100, resetAt: now.addingTimeInterval(3600)),
            secondary: QuotaWindow(label: "Weekly", used: 50, limit: 100, resetAt: now.addingTimeInterval(86_400)),
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: now,
            note: nil
        )
        let fire = state.nextResetBoundaryRefreshDate(for: snapshot, now: now)
        #expect(fire == now.addingTimeInterval(3600 + state.resetBoundaryRefreshLeeway))

        // Already-passed resets are ignored; with no future reset there is nothing to schedule.
        let expired = QuotaSnapshot(
            source: "Test",
            primary: QuotaWindow(label: "5h", used: 50, limit: 100, resetAt: now.addingTimeInterval(-10)),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: now,
            note: nil
        )
        #expect(state.nextResetBoundaryRefreshDate(for: expired, now: now) == nil)
    }

    @MainActor
    @Test("both credential sync entries absorb a pending-deletion account")
    func credentialSyncEntriesAbsorbPendingDeletion() async throws {
        let pendingIdentity = "claude-code:account:8FF17EA7-CE42-4001-AAAA-000000000001"
        let fixture = PendingDeletionSecretFixture()
        defer { fixture.cleanup() }
        let provider = PendingDeletionProvider(identity: pendingIdentity, importedSecret: "live-secret")
        let state = AppState(
            secretStore: fixture.store,
            providerRegistry: ProviderRegistry(overrides: [.claudeCode: provider])
        )
        var settings = AccountSettings.empty
        settings.identityKey = pendingIdentity
        let pending = Account(tool: .claudeCode, name: "Pending", settings: settings)
        let fallback = Account(tool: .claudeCode, name: "Fallback")
        state.accounts = [fallback]
        state.activeAccountByTool[.claudeCode] = fallback.id
        state.pendingDeletion = AppState.PendingAccountDeletion(
            account: pending,
            snapshot: nil,
            loadState: nil,
            wasActive: true,
            finalizeTask: nil
        )
        let pendingSecretKey = "account.\(pending.id.uuidString).secret"
        try fixture.store.saveSecret("stored-secret", accountKey: pendingSecretKey)

        #expect(await state.syncInstalledCurrentAccount(for: .claudeCode, intent: .local) == nil)
        #expect(try fixture.store.readSecret(accountKey: pendingSecretKey) == "live-secret")
        await state.refreshAfterCredentialChange(for: .claudeCode)

        #expect(state.accounts == [fallback])
        #expect(state.activeAccountByTool[.claudeCode] == fallback.id)
        #expect(state.pendingDeletion?.account.id == pending.id)
        #expect(try fixture.store.readSecret(accountKey: pendingSecretKey) == "live-secret")
    }

    @MainActor
    @Test("credential sync stays suppressed while physical deletion hands off the CLI")
    func credentialSyncIsSuppressedDuringFinalization() async {
        let identity = "claude-code:account:8ff17ea7-ce42-4001-aaaa-000000000001"
        let fixture = PendingDeletionSecretFixture()
        defer { fixture.cleanup() }
        let provider = PendingDeletionProvider(identity: identity, importedSecret: "live-secret")
        let state = AppState(
            secretStore: fixture.store,
            providerRegistry: ProviderRegistry(overrides: [.claudeCode: provider])
        )
        var settings = AccountSettings.empty
        settings.identityKey = identity
        let deleting = Account(tool: .claudeCode, name: "Deleting", settings: settings)
        let fallback = Account(tool: .claudeCode, name: "Fallback")
        state.accounts = [fallback]
        state.activeAccountByTool[.claudeCode] = fallback.id
        state.finalizingDeletionAccounts[deleting.id] = deleting

        #expect(await state.syncInstalledCurrentAccount(for: .claudeCode, intent: .local) == nil)
        await state.refreshAfterCredentialChange(for: .claudeCode)

        #expect(state.accounts == [fallback])
        #expect(state.activeAccountByTool[.claudeCode] == fallback.id)
        #expect((try? fixture.store.readSecret(
            accountKey: "account.\(deleting.id.uuidString).secret"
        )) == nil)
    }
}

private struct PendingDeletionProvider: Provider {
    let tool = ToolKind.claudeCode
    let identity: String
    let importedSecret: String

    func importCurrentCredentials() async throws -> String {
        importedSecret
    }

    func activate(account: Account, secret: String) async throws {
        _ = account
        _ = secret
    }

    func fetchQuota(secret: String) async throws -> QuotaSnapshot {
        _ = secret
        return QuotaSnapshot(
            source: "Test",
            primary: nil,
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(),
            note: nil
        )
    }

    func accountIdentity(from secret: String) -> String? {
        _ = secret
        return identity
    }

    func accountIdentityAliases(from secret: String) -> [String] {
        _ = secret
        return [identity]
    }

    func canSafelyReplaceInstalledCredentials(afterImport secret: String) -> Bool {
        _ = secret
        return true
    }
}

private final class PendingDeletionKeychain: SecretKeychainClient {
    private var storage: [String: Data] = [:]

    func saveSecret(_ data: Data, service: String, account: String) throws {
        storage["\(service)\n\(account)"] = data
    }

    func readSecret(service: String, account: String) throws -> Data? {
        storage["\(service)\n\(account)"]
    }

    func deleteSecret(service: String, account: String) throws {
        storage["\(service)\n\(account)"] = nil
    }
}

private struct PendingDeletionSecretFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaBarPendingDeletionTests-\(UUID().uuidString)", isDirectory: true)
    let store: SecretStoreService

    init() {
        store = SecretStoreService(
            keychain: PendingDeletionKeychain(),
            keychainService: "com.chiloh.QuotaBar.pending-deletion-tests.\(UUID().uuidString)",
            legacySecretsFile: directory.appendingPathComponent("secrets.json")
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
