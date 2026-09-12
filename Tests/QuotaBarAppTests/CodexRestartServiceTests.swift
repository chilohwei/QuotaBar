import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Codex restart planning")
struct CodexRestartServiceTests {
    private func process(_ pid: pid_t, _ path: String) -> CodexRestartService.RunningProcess {
        CodexRestartService.RunningProcess(pid: pid, executablePath: path)
    }

    @Test("processes inside an app bundle restart via the app; the rest are terminated directly")
    func planPartitionsByHost() {
        let plan = CodexRestartService.makeRestartPlan(for: [
            process(100, "/Applications/ChatGPT.app/Contents/Resources/codex"),
            process(200, "/opt/homebrew/bin/codex"),
            process(300, "/Users/dev/.vscode/extensions/openai.codex-1.2/bin/codex")
        ])
        #expect(plan.appBundlePaths == ["/Applications/ChatGPT.app"])
        #expect(plan.loosePIDs == [200, 300])
    }

    @Test("several processes from one bundle collapse into a single app restart")
    func planDeduplicatesBundles() {
        let plan = CodexRestartService.makeRestartPlan(for: [
            process(100, "/Applications/ChatGPT.app/Contents/Resources/codex"),
            process(101, "/Applications/ChatGPT.app/Contents/Helpers/codex")
        ])
        #expect(plan.appBundlePaths == ["/Applications/ChatGPT.app"])
        #expect(plan.loosePIDs.isEmpty)
    }

    @Test("owning bundle is the first .app segment of the executable path")
    func owningBundleExtraction() {
        #expect(
            CodexRestartService.owningAppBundlePath(of: "/Applications/ChatGPT.app/Contents/Resources/codex")
                == "/Applications/ChatGPT.app"
        )
        #expect(CodexRestartService.owningAppBundlePath(of: "/opt/homebrew/bin/codex") == nil)
        // Extension binaries under a dot-directory are not app bundles.
        #expect(CodexRestartService.owningAppBundlePath(of: "/Users/dev/.cursor/extensions/codex/bin/codex") == nil)
    }

    @Test("nothing running yields an empty plan (next launch reads the new auth anyway)")
    func emptyPlan() {
        let plan = CodexRestartService.makeRestartPlan(for: [])
        #expect(plan == CodexRestartService.RestartPlan())
    }
}
