import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Codex login")
struct CodexProviderLoginTests {
    @Test("discovers supported ChatGPT CLI bundle layouts", arguments: [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Users/tester/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Users/tester/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    ])
    func findsChatGPTBundledCodexCLI(path: String) {
        let candidates = CodexProvider().explicitCodexExecutableURLs(home: "/Users/tester")
        #expect(candidates.contains(URL(fileURLWithPath: path)))
    }

    @Test("Codex login tries the browser before device authorization and saves credentials to a file")
    func everyLoginAttemptForcesFileCredentialStorage() {
        let attempts = CodexProvider().codexLoginAttempts()

        #expect(attempts.map(\.opensDevicePrompt) == [false, true])
        #expect(attempts.map { $0.arguments.contains("--device-auth") } == [false, true])
        #expect(attempts.allSatisfy {
            $0.arguments.contains(#"cli_auth_credentials_store="file""#)
        })
    }
}
