import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Codex login")
struct CodexProviderLoginTests {
    @Test("finds the Codex CLI bundled with ChatGPT")
    func findsChatGPTBundledCodexCLI() {
        let candidates = CodexProvider().explicitCodexExecutableURLs(home: "/Users/tester")

        #expect(candidates.contains(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")))
    }
}
