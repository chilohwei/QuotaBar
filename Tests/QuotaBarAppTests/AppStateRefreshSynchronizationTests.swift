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
