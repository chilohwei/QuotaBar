import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Codex registry", .serialized)
struct CodexProviderRegistryTests {
    @Test("prepareAccount keeps registry active account unchanged")
    func prepareAccountDoesNotChangeActiveSelection() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = tempRoot.appendingPathComponent("codex-home", isDirectory: true)
        let managedHome = tempRoot.appendingPathComponent("managed-home", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("CODEX_HOME", codexHome.path, 1)
        defer {
            unsetenv("CODEX_HOME")
            try? fileManager.removeItem(at: tempRoot)
        }

        let provider = CodexProvider()
        var account = Account(tool: .codex, name: "Added account")
        account.settings.codexHomePath = managedHome.path

        let secret = codexSecret(
            email: "added@example.com",
            userID: "user-123",
            accountID: "acct-456"
        )

        let prepared = try await provider.prepareAccount(account, secret: secret)
        let registryURL = codexHome.appendingPathComponent("accounts/registry.json")
        let registry = try jsonDictionary(at: registryURL)

        #expect(prepared.settings.codexHomePath == managedHome.path)
        #expect((registry["active_account_key"] as? String) == nil)

        let accounts = registry["accounts"] as? [[String: Any]] ?? []
        #expect(accounts.count == 1)
        #expect(accounts.first?["account_key"] as? String == "user-123::acct-456")

        try await provider.activate(account: prepared, secret: secret)
        let activatedRegistry = try jsonDictionary(at: registryURL)
        #expect((activatedRegistry["active_account_key"] as? String) == "user-123::acct-456")
    }

    @Test("activation forces file credential store so auth.json switching is honored")
    func activationForcesFileCredentialStore() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = tempRoot.appendingPathComponent("codex-home", isDirectory: true)
        let managedHome = tempRoot.appendingPathComponent("managed-home", isDirectory: true)
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: managedHome, withIntermediateDirectories: true)
        setenv("CODEX_HOME", codexHome.path, 1)
        defer {
            unsetenv("CODEX_HOME")
            try? fileManager.removeItem(at: tempRoot)
        }

        try """
        model = "gpt-5.4"
        cli_auth_credentials_store = "keyring"

        [shell_environment_policy]
        inherit = "all"
        """.write(to: managedHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let provider = CodexProvider()
        var account = Account(tool: .codex, name: "Device account")
        account.settings.codexHomePath = managedHome.path
        let secret = codexSecret(
            email: "device@example.com",
            userID: "user-device",
            accountID: "acct-device"
        )

        try await provider.activate(account: account, secret: secret)

        let activeConfig = try String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        #expect(activeConfig.contains(#"cli_auth_credentials_store = "file""#))
        #expect(activeConfig.contains(#"model = "gpt-5.4""#))
        #expect(activeConfig.contains("[shell_environment_policy]"))
        #expect(try backupExists(named: "config.toml", in: codexHome))
    }

    @Test("registry writes compatible timestamps, preserves aliases, and creates backups")
    func registryCompatibilityAndBackups() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = tempRoot.appendingPathComponent("codex-home", isDirectory: true)
        let accountsDirectory = codexHome.appendingPathComponent("accounts", isDirectory: true)
        let managedHome = tempRoot.appendingPathComponent("managed-home", isDirectory: true)
        try fileManager.createDirectory(at: accountsDirectory, withIntermediateDirectories: true)
        setenv("CODEX_HOME", codexHome.path, 1)
        defer {
            unsetenv("CODEX_HOME")
            try? fileManager.removeItem(at: tempRoot)
        }

        let registryURL = accountsDirectory.appendingPathComponent("registry.json")
        try writeJSONObject([
            "schema_version": 3,
            "active_account_key": "other-user::other-account",
            "active_account_activated_at_ms": 1_700_000_000_000,
            "custom_top_level_field": "kept",
            "accounts": [
                [
                    "account_key": "user-123::acct-456",
                    "chatgpt_account_id": "acct-456",
                    "chatgpt_user_id": "user-123",
                    "email": "old@example.com",
                    "alias": "Work Alias",
                    "account_name": "Old Workspace",
                    "plan": "plus",
                    "created_at": 1_700_000_000,
                    "last_used_at": 1_700_000_001
                ],
                [
                    "account_key": "other-user::other-account",
                    "chatgpt_account_id": "other-account",
                    "chatgpt_user_id": "other-user",
                    "email": "other@example.com",
                    "created_at": 1_700_000_010
                ]
            ],
            "api": [
                "account": true,
                "usage": true
            ],
            "auto_switch": [
                "enabled": false,
                "threshold_5h_percent": 10,
                "threshold_weekly_percent": 5
            ]
        ], to: registryURL)
        try "old-auth".write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let provider = CodexProvider()
        var account = Account(tool: .codex, name: "added@example.com")
        account.settings.codexHomePath = managedHome.path
        let secret = codexSecret(
            email: "added@example.com",
            userID: "user-123",
            accountID: "acct-456"
        )

        let prepared = try await provider.prepareAccount(account, secret: secret)
        let preparedRegistry = try jsonDictionary(at: registryURL)
        let preparedAccount = try #require(registryAccount("user-123::acct-456", in: preparedRegistry))

        #expect(prepared.settings.codexHomePath == managedHome.path)
        #expect((preparedRegistry["active_account_key"] as? String) == "other-user::other-account")
        #expect((preparedRegistry["custom_top_level_field"] as? String) == "kept")
        #expect(preparedAccount["alias"] as? String == "Work Alias")
        #expect((preparedAccount["created_at"] as? Int ?? 0) < 2_000_000_000)
        #expect((preparedAccount["last_used_at"] as? Int ?? 0) == 1_700_000_001)

        try await provider.activate(account: prepared, secret: secret)
        let activatedRegistry = try jsonDictionary(at: registryURL)
        let activatedAccount = try #require(registryAccount("user-123::acct-456", in: activatedRegistry))

        #expect((activatedRegistry["active_account_key"] as? String) == "user-123::acct-456")
        #expect((activatedRegistry["active_account_activated_at_ms"] as? Int ?? 0) > 2_000_000_000)
        #expect((activatedAccount["alias"] as? String) == "Work Alias")
        #expect((activatedAccount["last_used_at"] as? Int ?? 0) < 2_000_000_000)
        #expect(try backupExists(named: "registry.json", in: accountsDirectory))
        #expect(try backupExists(named: "auth.json", in: codexHome))
    }

    @Test("stored usage snapshot maps quota into codex registry format")
    func storedUsageSnapshotMapping() {
        let snapshot = QuotaSnapshot(
            source: "Codex OAuth",
            accountIdentifier: "user@example.com",
            planName: "Plus Annual",
            primary: QuotaWindow(
                label: "5 小时使用限额",
                used: 40,
                limit: 100,
                resetAt: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            secondary: QuotaWindow(
                label: "每周使用限额",
                used: 10,
                limit: 100,
                resetAt: Date(timeIntervalSince1970: 1_700_010_000)
            ),
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            note: nil
        )

        let stored = CodexStoredUsageSnapshot(snapshot: snapshot)

        #expect(stored.planType == "plus")
        #expect(stored.primary?.usedPercent == 40)
        #expect(stored.primary?.windowMinutes == 300)
        #expect(stored.primary?.resetsAt == 1_700_000_100)
        #expect(stored.secondary?.windowMinutes == 10_080)
    }

    private func codexSecret(email: String, userID: String, accountID: String) -> String {
        let idToken = jwt(payload: [
            "email": email,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
                "chatgpt_user_id": userID
            ]
        ])

        return """
        {
          "tokens": {
            "access_token": "access-token",
            "id_token": "\(idToken)"
          },
          "last_refresh": "2026-05-15T00:00:00Z"
        }
        """
    }

    private func jwt(payload: [String: Any]) -> String {
        let header = base64URL(#"{"alg":"none"}"#)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let payloadText = String(data: payloadData, encoding: .utf8)!
        return "\(header).\(base64URL(payloadText)).signature"
    }

    private func base64URL(_ text: String) -> String {
        Data(text.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func jsonDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        return json as? [String: Any] ?? [:]
    }

    private func registryAccount(_ accountKey: String, in registry: [String: Any]) -> [String: Any]? {
        let accounts = registry["accounts"] as? [[String: Any]] ?? []
        return accounts.first { ($0["account_key"] as? String) == accountKey }
    }

    private func writeJSONObject(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func backupExists(named baseName: String, in directory: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix("\(baseName).bak.") }
    }
}
