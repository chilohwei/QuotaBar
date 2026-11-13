import Foundation
import Testing
@testable import QuotaBarApp

@MainActor
@Suite("Add account authentication")
struct AppStateAddAccountTests {
    @Test("adding ChatGPT opens browser authorization even with an untracked local account")
    func codexUsesBrowserInsteadOfImportingLocalAccount() async throws {
        let provider = AddAccountProvider(tool: .codex)
        let state = makeState(provider: provider)

        let result = try await state.quickAddSecret(tool: .codex, provider: provider)

        #expect(result.secret == "browser-secret")
        #expect(!result.matchesExistingAccount)
        #expect(await provider.calls == [.browser(allowExistingCredentials: false)])
        #expect(state.addAccountPhase == .waitingBrowserAuthorization)
        #expect(state.accounts.isEmpty)
    }

    @Test("reauthorizing a stored ChatGPT account still opens the browser and detects the duplicate")
    func codexBrowserResultCanMatchStoredAccount() async throws {
        let provider = AddAccountProvider(tool: .codex)
        let state = makeState(provider: provider)
        var settings = AccountSettings.empty
        settings.identityKey = provider.accountIdentity(from: "browser-secret")
        let stored = Account(tool: .codex, name: "Stored account", settings: settings)
        state.accounts = [stored]
        state.activeAccountByTool[.codex] = stored.id

        let result = try await state.quickAddSecret(tool: .codex, provider: provider)

        #expect(result.secret == "browser-secret")
        #expect(result.matchesExistingAccount)
        #expect(await provider.calls == [.browser(allowExistingCredentials: false)])
        #expect(state.accounts == [stored])
        #expect(state.activeAccountByTool[.codex] == stored.id)
    }

    @Test("unsuccessful ChatGPT authorization leaves local credentials untouched", arguments: BrowserInterruption.allCases)
    func codexBrowserInterruptionDoesNotImportLocalAccount(interruption: BrowserInterruption) async {
        let provider = AddAccountProvider(tool: .codex, interruption: interruption)
        let state = makeState(provider: provider)

        do {
            _ = try await state.quickAddSecret(tool: .codex, provider: provider)
            Issue.record("Expected browser authorization to throw")
        } catch {
            switch interruption {
            case .failure:
                #expect(error as? AddAccountTestError == .browserFailure)
            case .cancellation:
                #expect(error is CancellationError)
            }
        }

        #expect(await provider.calls == [.browser(allowExistingCredentials: false)])
        #expect(state.accounts.isEmpty)
    }

    @Test("other tools retain local account import", arguments: [ToolKind.cursor, .claudeCode])
    func otherToolsStillImportLocalAccount(tool: ToolKind) async throws {
        let provider = AddAccountProvider(tool: tool)
        let state = makeState(provider: provider)

        let result = try await state.quickAddSecret(tool: tool, provider: provider)

        #expect(result.secret == "local-secret")
        #expect(!result.matchesExistingAccount)
        #expect(await provider.calls == [.importLocal])
        #expect(state.addAccountPhase == .importingLocal)
    }

    private func makeState(provider: AddAccountProvider) -> AppState {
        let isolatedSecrets = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarAddAccountTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("secrets.json")
        return AppState(
            secretStore: SecretStoreService(
                keychain: AddAccountTestKeychain(),
                keychainService: "com.chiloh.QuotaBar.add-account-tests.\(UUID().uuidString)",
                legacySecretsFile: isolatedSecrets
            ),
            providerRegistry: ProviderRegistry(overrides: [provider.tool: provider])
        )
    }
}

enum BrowserInterruption: CaseIterable, Sendable {
    case failure
    case cancellation
}

private enum AddAccountTestError: Error {
    case browserFailure
    case unexpectedOperation
}

private actor AddAccountProvider: Provider {
    enum Call: Equatable {
        case importLocal
        case browser(allowExistingCredentials: Bool)
    }

    let tool: ToolKind
    private let interruption: BrowserInterruption?
    private(set) var calls: [Call] = []

    init(tool: ToolKind, interruption: BrowserInterruption? = nil) {
        self.tool = tool
        self.interruption = interruption
    }

    func importCurrentCredentials() async throws -> String {
        calls.append(.importLocal)
        return "local-secret"
    }

    func authenticateViaBrowser(allowExistingCredentials: Bool) async throws -> String {
        calls.append(.browser(allowExistingCredentials: allowExistingCredentials))
        switch interruption {
        case .failure: throw AddAccountTestError.browserFailure
        case .cancellation: throw CancellationError()
        case nil: return "browser-secret"
        }
    }

    nonisolated func accountIdentity(from secret: String) -> String? {
        "\(tool.rawValue):\(secret)"
    }

    func activate(account: Account, secret: String) async throws {
        throw AddAccountTestError.unexpectedOperation
    }

    func fetchQuota(secret: String) async throws -> QuotaSnapshot {
        throw AddAccountTestError.unexpectedOperation
    }
}

private struct AddAccountTestKeychain: SecretKeychainClient {
    func saveSecret(_ data: Data, service: String, account: String) throws {
        throw AddAccountTestError.unexpectedOperation
    }

    func readSecret(service: String, account: String) throws -> Data? {
        nil
    }

    func deleteSecret(service: String, account: String) throws {
        throw AddAccountTestError.unexpectedOperation
    }
}
