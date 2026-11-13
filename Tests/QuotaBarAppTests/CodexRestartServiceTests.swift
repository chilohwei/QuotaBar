import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Codex restart planning")
struct CodexRestartServiceTests {
    struct PlanCase: Sendable {
        let processes: [(pid: pid_t, path: String)]
        let appBundlePaths: [String]
        let loosePIDs: [pid_t]
    }

    @Test("restart plans partition loose processes and deduplicate their outer app bundles", arguments: [
        PlanCase(
            processes: [
                (100, "/Applications/ChatGPT.app/Contents/Resources/codex"),
                (200, "/opt/homebrew/bin/codex"),
                (300, "/Users/dev/.vscode/extensions/openai.codex-1.2/bin/codex")
            ],
            appBundlePaths: ["/Applications/ChatGPT.app"],
            loosePIDs: [200, 300]
        ),
        PlanCase(
            processes: [
                (100, "/Applications/ChatGPT.app/Contents/Resources/codex"),
                (101, "/Applications/ChatGPT.app/Contents/Helpers/codex")
            ],
            appBundlePaths: ["/Applications/ChatGPT.app"],
            loosePIDs: []
        ),
        PlanCase(
            processes: [
                (100, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
                (200, "/Users/dev/.cursor/extensions/codex/bin/codex")
            ],
            appBundlePaths: ["/Applications/ChatGPT.app"],
            loosePIDs: [200]
        ),
        PlanCase(processes: [], appBundlePaths: [], loosePIDs: [])
    ])
    func restartPlan(testCase: PlanCase) {
        let plan = CodexRestartService.makeRestartPlan(for: testCase.processes.map {
            CodexRestartService.RunningProcess(pid: $0.pid, executablePath: $0.path)
        })
        #expect(plan.appBundlePaths == testCase.appBundlePaths)
        #expect(plan.loosePIDs == testCase.loosePIDs)
    }
}
