import Foundation
import Testing
@testable import QuotaBarApp

@Suite("AppState restart re-assertion")
struct AppStateRestartReassertionTests {
    @MainActor
    @Test("a restarted tool's own credential write cannot take the active slot")
    func restartWindowBlocksImportedCredentialsFromBecomingActive() {
        let state = AppState()
        let account = Account(tool: .codex, name: "codex@example.com")
        state.accounts = [account]
        state.activeAccountByTool[.codex] = account.id
        let provider = state.provider(for: .codex)

        // Outside a restart, whatever Codex is signed into is the selection.
        #expect(state.importedCredentialsSelectActiveAccount(for: .codex, provider: provider))

        state.scheduleActiveSelectionReassertion(for: .codex)

        // Inside the window, a bounced `codex` writing the previous account back is not the user
        // choosing it — the account is still recorded, it just cannot claim the active slot.
        #expect(state.restartReassertionByTool[.codex]?.accountID == account.id)
        #expect(!state.importedCredentialsSelectActiveAccount(for: .codex, provider: provider))

        state.restartReassertionTasks[.codex]?.cancel()
    }

    @MainActor
    @Test("Claude Code schedules no re-assertion")
    func claudeCodeIsExcludedFromReassertion() {
        let state = AppState()
        let account = Account(tool: .claudeCode, name: "claude@example.com")
        state.accounts = [account]
        state.activeAccountByTool[.claudeCode] = account.id

        state.scheduleActiveSelectionReassertion(for: .claudeCode)

        #expect(state.restartReassertionByTool[.claudeCode] == nil)
        #expect(state.restartReassertionTasks[.claudeCode] == nil)
    }

    @MainActor
    @Test("installed credentials are matched against the account's identity key")
    func installedCredentialsAreMatchedByIdentity() {
        let state = AppState()
        let provider = state.provider(for: .codex)

        var settings = AccountSettings.empty
        settings.identityKey = "email:wanted@example.com"
        let account = Account(tool: .codex, name: "wanted@example.com", settings: settings)

        let wanted = authPayload(email: "wanted@example.com")
        let other = authPayload(email: "other@example.com")

        #expect(state.installedCredentials(wanted, belongTo: account, provider: provider))
        #expect(!state.installedCredentials(other, belongTo: account, provider: provider))

        // Records predating identity metadata cannot be verified, so they are left alone rather
        // than having their credentials rewritten on a guess.
        let legacy = Account(tool: .codex, name: "wanted@example.com")
        #expect(state.installedCredentials(other, belongTo: legacy, provider: provider))
    }

    /// A minimal `~/.codex/auth.json` whose id_token carries only the email claim.
    private func authPayload(email: String) -> String {
        let claims = try! JSONSerialization.data(withJSONObject: ["email": email])
        let idToken = ["e30", base64URL(claims), "signature"].joined(separator: ".")
        return #"{"tokens":{"id_token":"\#(idToken)"}}"#
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
