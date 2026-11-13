import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Refresh policy")
struct RefreshPolicyTests {
    struct RefreshIntervalCase: Sendable {
        enum ExpectedInterval: Sendable {
            case lowQuota
            case powerSaving
            case standard
        }

        let batteryPowered: Bool
        let idleDuration: TimeInterval
        let remainingRatios: [Double]
        let expected: ExpectedInterval
    }

    @Test("refresh interval follows active quota, power, and idle state", arguments: [
        RefreshIntervalCase(batteryPowered: false, idleDuration: 0, remainingRatios: [0.8, 0.19], expected: .lowQuota),
        RefreshIntervalCase(batteryPowered: true, idleDuration: 600, remainingRatios: [0.1], expected: .powerSaving),
        RefreshIntervalCase(batteryPowered: false, idleDuration: 600, remainingRatios: [0.6], expected: .standard)
    ])
    func automaticRefreshInterval(testCase: RefreshIntervalCase) {
        let policy = RefreshIntervalPolicy(
            isOnBatteryPower: { testCase.batteryPowered },
            userIdleDuration: { testCase.idleDuration }
        )
        let expected = switch testCase.expected {
        case .lowQuota: policy.lowQuotaInterval
        case .powerSaving: policy.powerSavingInterval
        case .standard: policy.defaultInterval
        }
        #expect(policy.automaticRefreshInterval(activeRemainingRatios: testCase.remainingRatios) == expected)
    }

    @Test("local refresh bypasses only the app failure backoff")
    func localRefreshBackoffPolicy() {
        #expect(RefreshIntent.local.bypassesAppBackoff)
        #expect(!RefreshIntent.local.bypassesProviderCache)
        #expect(!RefreshIntent.local.allowsProviderCredentialRefresh)
        #expect(RefreshIntent.local.preservesAppBackoffAfterSuccess)
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
        #expect(factory.claudeIdentityURL().path == "/tmp/quotabar-home/.claude.json")
        #expect(factory.watchTargets().contains(
            RefreshWatchTarget(
                url: URL(fileURLWithPath: "/tmp/quotabar-home/.claude.json"),
                reason: .credentialsChanged(.claudeCode)
            )
        ))
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
