import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Refresh policy")
struct RefreshPolicyTests {
    @Test("low active quota uses faster interval")
    func lowActiveQuotaUsesFasterInterval() {
        let policy = RefreshIntervalPolicy(
            isOnBatteryPower: { false },
            userIdleDuration: { 0 }
        )

        #expect(policy.automaticRefreshInterval(activeRemainingRatios: [0.8, 0.19]) == policy.lowQuotaInterval)
    }

    @Test("battery idle state uses power saving interval")
    func batteryIdleUsesPowerSavingInterval() {
        let policy = RefreshIntervalPolicy(
            isOnBatteryPower: { true },
            userIdleDuration: { 600 }
        )

        #expect(policy.automaticRefreshInterval(activeRemainingRatios: [0.1]) == policy.powerSavingInterval)
    }

    @Test("normal state uses default interval")
    func normalStateUsesDefaultInterval() {
        let policy = RefreshIntervalPolicy(
            isOnBatteryPower: { false },
            userIdleDuration: { 600 }
        )

        #expect(policy.automaticRefreshInterval(activeRemainingRatios: [0.6]) == policy.defaultInterval)
    }
}

@Suite("Refresh watch target factory")
struct RefreshWatchTargetFactoryTests {
    @Test("resolves configured credential paths")
    func resolvesConfiguredCredentialPaths() {
        let home = URL(fileURLWithPath: "/tmp/quotabar-home", isDirectory: true)
        let factory = RefreshWatchTargetFactory(
            environment: [
                "CODEX_HOME": "/tmp/codex-home",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-config"
            ],
            homeDirectory: home
        )

        #expect(factory.codexAuthURL().path == "/tmp/codex-home/auth.json")
        #expect(factory.claudeCodeAuthURL().path == "/tmp/claude-config/auth.json")
        #expect(factory.cursorStateDatabaseURLs().map(\.path) == [
            "/tmp/quotabar-home/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            "/tmp/quotabar-home/Library/Application Support/Cursor - Insiders/User/globalStorage/state.vscdb",
            "/tmp/quotabar-home/Library/Application Support/Cursor Nightly/User/globalStorage/state.vscdb"
        ])
    }

    @Test("xdg config is used for Claude Code when explicit config is absent")
    func xdgConfigIsUsedForClaudeCode() {
        let factory = RefreshWatchTargetFactory(
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )

        #expect(factory.claudeCodeAuthURL().path == "/tmp/xdg/claude-code/auth.json")
    }
}
