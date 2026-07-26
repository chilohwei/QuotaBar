import CryptoKit
import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Provider identity")
struct ProviderIdentityTests {
    @Test("Cursor identity aliases include stable refresh token fallback")
    func cursorIdentityAliasesIncludeRefreshTokenFallback() {
        let accessToken = jwt(payload: [
            "sub": "User-123",
            "email": "USER@example.com"
        ])
        let secret = """
        {
          "accessToken": "\(accessToken)",
          "refreshToken": "cursor-refresh-token-stable",
          "email": null,
          "membershipType": null,
          "subscriptionStatus": null,
          "subscriptionPeriodEnd": null,
          "stateDatabasePath": null,
          "source": null
        }
        """

        let aliases = CursorProvider().accountIdentityAliases(from: secret)

        #expect(aliases.first == "cursor:sub:user-123")
        #expect(aliases.contains("cursor:email:user@example.com"))
        #expect(aliases.contains("cursor:refresh:esh-token-stable"))
        #expect(aliases.contains("cursor:token:\(accessToken.suffix(16))"))
    }

    @Test("Cursor add flow rejects existing account when a new account is required")
    func cursorAddFlowRejectsExistingAccountWhenNewAccountIsRequired() throws {
        let provider = CursorProvider()
        let existingSecret = cursorSecret(
            accessToken: jwt(payload: [
                "sub": "User-123",
                "email": "USER@example.com"
            ])
        )
        let newSecret = cursorSecret(
            accessToken: jwt(payload: [
                "sub": "User-456",
                "email": "OTHER@example.com"
            ])
        )
        let existingCredentials = try provider.parseCredentials(existingSecret)

        #expect(provider.cursorImportedSecret(
            existingSecret,
            isAcceptableComparedTo: existingCredentials,
            allowExistingCredentials: true
        ))
        #expect(!provider.cursorImportedSecret(
            existingSecret,
            isAcceptableComparedTo: existingCredentials,
            allowExistingCredentials: false
        ))
        #expect(provider.cursorImportedSecret(
            newSecret,
            isAcceptableComparedTo: existingCredentials,
            allowExistingCredentials: false
        ))
    }

    @Test("Claude identity aliases keep keychain fingerprint and legacy fallback")
    func claudeIdentityAliasesKeepFingerprintAndLegacyFallback() {
        let keychainCredentials = "claude-keychain-secret"
        let secret = """
        {
          "loggedIn": true,
          "authMethod": "oauth",
          "apiProvider": "firstParty",
          "userID": null,
          "claudeExecutablePath": null,
          "keychainCredentials": "\(keychainCredentials)",
          "authStatusJSON": null,
          "claudeSettingsJSON": null,
          "claudeJSON": null,
          "claudeCredentialsJSON": null,
          "claudeAuthJSON": null
        }
        """

        let aliases = ClaudeCodeProvider().accountIdentityAliases(from: secret)

        #expect(aliases.first == "claude-code:keychain:\(fingerprint(keychainCredentials))")
        #expect(aliases.contains("claude-code:oauth:firstParty"))
    }

    @Test("Claude aliases distinguish accounts sharing the machine-scoped userID")
    func claudeAliasesDistinguishAccountsSharingMachineUserID() {
        // `~/.claude.json`'s userID is minted once per installation and never rotates on login,
        // so both accounts carry the same value; identity must come from account-scoped fields.
        let machineUserID = "4d3028faff65cb8ff91ccab671de085widely-shared"
        let first = claudeSecret(
            userID: machineUserID,
            accountUuid: "8ff17ea7-ce42-4001-aaaa-000000000001",
            email: "first@example.com",
            keychainCredentials: keychainJSON(accessToken: "token-a", refreshToken: "refresh-a")
        )
        let second = claudeSecret(
            userID: machineUserID,
            accountUuid: "11111111-2222-4333-bbbb-000000000002",
            email: "second@example.com",
            keychainCredentials: keychainJSON(accessToken: "token-b", refreshToken: "refresh-b")
        )
        let provider = ClaudeCodeProvider()

        let firstAliases = provider.accountIdentityAliases(from: first)
        let secondAliases = provider.accountIdentityAliases(from: second)

        #expect(firstAliases.first == "claude-code:account:8ff17ea7-ce42-4001-aaaa-000000000001")
        #expect(secondAliases.first == "claude-code:account:11111111-2222-4333-bbbb-000000000002")
        #expect(firstAliases.contains("claude-code:email:first@example.com"))
        // The only alias two distinct first-party accounts may share is the legacy
        // method:provider fallback — never anything derived from the machine-scoped userID.
        #expect(Set(firstAliases).intersection(Set(secondAliases)) == ["claude-code:oauth:firstParty"])
        #expect(!secondAliases.contains(where: { $0.hasPrefix("claude-code:user:") }))

        let firstCredentials = try! provider.parseCredentials(first)
        let secondCredentials = try! provider.parseCredentials(second)
        #expect(!provider.claudeCredentialsRepresentSameAccount(firstCredentials, secondCredentials))
        #expect(provider.shouldClearStatusLineSnapshot(previous: firstCredentials, next: secondCredentials))
    }

    @Test("Claude same-account check survives token rotation and ignores userID")
    func claudeSameAccountCheckSurvivesTokenRotation() {
        let provider = ClaudeCodeProvider()
        let before = claudeSecret(
            userID: "machine-id",
            accountUuid: "8ff17ea7-ce42-4001-aaaa-000000000001",
            email: "first@example.com",
            keychainCredentials: keychainJSON(accessToken: "token-old", refreshToken: "refresh-old")
        )
        let after = claudeSecret(
            userID: "machine-id",
            accountUuid: "8FF17EA7-CE42-4001-AAAA-000000000001",
            email: "first@example.com",
            keychainCredentials: keychainJSON(accessToken: "token-new", refreshToken: "refresh-new")
        )

        let beforeCredentials = try! provider.parseCredentials(before)
        let afterCredentials = try! provider.parseCredentials(after)

        #expect(provider.claudeCredentialsRepresentSameAccount(beforeCredentials, afterCredentials))
        #expect(!provider.shouldClearStatusLineSnapshot(previous: beforeCredentials, next: afterCredentials))
    }

    @Test("Claude usage cache keys are account-scoped despite shared userID")
    func claudeUsageCacheKeysAreAccountScoped() {
        let provider = ClaudeCodeProvider()
        let first = try! provider.parseCredentials(claudeSecret(
            userID: "machine-id",
            accountUuid: "8ff17ea7-ce42-4001-aaaa-000000000001",
            email: "first@example.com",
            keychainCredentials: keychainJSON(accessToken: "token-a", refreshToken: "refresh-a")
        ))
        let second = try! provider.parseCredentials(claudeSecret(
            userID: "machine-id",
            accountUuid: "11111111-2222-4333-bbbb-000000000002",
            email: "second@example.com",
            keychainCredentials: keychainJSON(accessToken: "token-b", refreshToken: "refresh-b")
        ))

        let firstKey = provider.usageCacheKey(first)
        let secondKey = provider.usageCacheKey(second)

        #expect(firstKey != nil)
        #expect(secondKey != nil)
        #expect(firstKey != secondKey)
    }

    @Test("Claude rotated token pair is embedded into stored credential artifacts")
    func claudeRotatedTokenPairIsEmbeddedIntoStoredArtifacts() throws {
        let provider = ClaudeCodeProvider()
        let stored = try provider.parseCredentials(claudeSecret(
            userID: "machine-id",
            accountUuid: "8ff17ea7-ce42-4001-aaaa-000000000001",
            email: "first@example.com",
            keychainCredentials: keychainJSON(accessToken: "token-old", refreshToken: "refresh-old")
        ))
        let rotated = ClaudeCodeProvider.RefreshedOAuthToken(
            accessToken: "token-new",
            refreshToken: "refresh-new",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let updated = try #require(provider.replacingOAuthToken(in: stored, with: rotated))
        let token = try #require(provider.parseOAuthToken(from: updated))

        #expect(token.accessToken == "token-new")
        #expect(token.refreshToken == "refresh-new")
        #expect(updated.claudeJSON == stored.claudeJSON)
        // Identity is untouched by rotation.
        #expect(provider.claudeCredentialsRepresentSameAccount(stored, updated))
    }

    @Test("Claude oauthAccount merge preserves live project history and caches")
    func claudeOAuthAccountMergePreservesLiveState() throws {
        let provider = ClaudeCodeProvider()
        let stored = try provider.parseCredentials(claudeSecret(
            userID: "machine-id",
            accountUuid: "11111111-2222-4333-bbbb-000000000002",
            email: "second@example.com",
            keychainCredentials: keychainJSON(accessToken: "token-b", refreshToken: "refresh-b")
        ))
        // A live ~/.claude.json mid-session: prompt history, caches, and the other account.
        let live: [String: Any] = [
            "userID": "machine-id",
            "hasCompletedOnboarding": true,
            "projects": ["/Users/me/repo": ["history": [["display": "fix the bug"]]]],
            "oauthAccount": [
                "accountUuid": "8ff17ea7-ce42-4001-aaaa-000000000001",
                "emailAddress": "first@example.com"
            ]
        ]

        let merged = try #require(provider.mergingClaudeOAuthAccount(into: live, from: stored))

        let oauthAccount = try #require(merged["oauthAccount"] as? [String: Any])
        #expect(oauthAccount["accountUuid"] as? String == "11111111-2222-4333-bbbb-000000000002")
        #expect(oauthAccount["emailAddress"] as? String == "second@example.com")
        // Session-continuity state survives the account switch untouched.
        #expect(merged["projects"] != nil)
        #expect(merged["hasCompletedOnboarding"] as? Bool == true)
        #expect(merged["userID"] as? String == "machine-id")

        // No oauthAccount in the stored snapshot → nothing to merge, live file left alone.
        let bare = try provider.parseCredentials(#"{"loggedIn": true, "claudeJSON": "{}"}"#)
        #expect(provider.mergingClaudeOAuthAccount(into: live, from: bare) == nil)
    }

    @Test("Claude plan name reflects real subscription tier")
    func claudePlanNameReflectsRealSubscriptionTier() throws {
        let provider = ClaudeCodeProvider()

        // Max 20x straight from the keychain token payload.
        let maxKeychain = jsonText([
            "claudeAiOauth": [
                "accessToken": "token-a",
                "refreshToken": "refresh-a",
                "subscriptionType": "max",
                "rateLimitTier": "default_claude_max_20x"
            ]
        ])
        let maxCredentials = try provider.parseCredentials(claudeSecret(
            userID: "machine-id",
            accountUuid: "8ff17ea7-ce42-4001-aaaa-000000000001",
            email: "first@example.com",
            keychainCredentials: maxKeychain
        ))
        #expect(provider.planName(credentials: maxCredentials, status: nil) == "Claude Max 20x")

        // Pro without a multiplier suffix.
        #expect(provider.claudeSubscriptionDisplayName(type: "pro", tier: "default_claude_pro") == "Claude Pro")
        #expect(provider.claudeSubscriptionDisplayName(type: "max", tier: "default_claude_max_5x") == "Claude Max 5x")
        #expect(provider.claudeSubscriptionDisplayName(type: nil, tier: "default_claude_max_5x") == nil)

        // No subscription fields anywhere → generic label, as before.
        let plainCredentials = try provider.parseCredentials(claudeSecret(
            userID: "machine-id",
            accountUuid: "8ff17ea7-ce42-4001-aaaa-000000000001",
            email: "first@example.com",
            keychainCredentials: keychainJSON(accessToken: "token-a", refreshToken: "refresh-a")
        ))
        #expect(provider.planName(credentials: plainCredentials, status: nil) == "Claude.ai")

        // Keychain lacks the field but the cached oauthAccount profile knows the org tier.
        let orgSecret: [String: Any] = [
            "loggedIn": true,
            "authMethod": "oauth",
            "apiProvider": "firstParty",
            "claudeJSON": jsonText([
                "oauthAccount": [
                    "accountUuid": "8ff17ea7-ce42-4001-aaaa-000000000001",
                    "organizationType": "claude_max",
                    "organizationRateLimitTier": "default_claude_max_20x"
                ]
            ])
        ]
        let orgCredentials = try provider.parseCredentials(jsonText(orgSecret))
        #expect(provider.planName(credentials: orgCredentials, status: nil) == "Claude Max 20x")
    }

    @Test("Claude account name prefers email over generated user suffix")
    func claudeAccountNamePrefersEmailOverGeneratedUserSuffix() {
        let secret = #"""
        {
          "loggedIn": true,
          "authMethod": "oauth",
          "apiProvider": "firstParty",
          "userID": "user-12345678",
          "claudeExecutablePath": null,
          "keychainCredentials": null,
          "authStatusJSON": "{ \"email\": \"CLAUDE-USER@example.com\" }",
          "claudeSettingsJSON": null,
          "claudeJSON": null,
          "claudeCredentialsJSON": null,
          "claudeAuthJSON": null
        }
        """#

        #expect(ClaudeCodeProvider().suggestAccountName(from: secret) == "claude-user@example.com")
    }

    /// A stored Claude secret the way QuotaBar captures it: `auth status` output, the
    /// `~/.claude.json` copy carrying `oauthAccount`, and the keychain credential text.
    private func claudeSecret(
        userID: String,
        accountUuid: String,
        email: String,
        keychainCredentials: String
    ) -> String {
        let authStatus: [String: Any] = [
            "loggedIn": true,
            "authMethod": "claude.ai",
            "apiProvider": "firstParty",
            "email": email
        ]
        let claudeJSON: [String: Any] = [
            "userID": userID,
            "oauthAccount": [
                "accountUuid": accountUuid,
                "emailAddress": email
            ]
        ]
        let secret: [String: Any] = [
            "loggedIn": true,
            "authMethod": "oauth",
            "apiProvider": "firstParty",
            "userID": userID,
            "keychainCredentials": keychainCredentials,
            "authStatusJSON": jsonText(authStatus),
            "claudeJSON": jsonText(claudeJSON)
        ]
        return jsonText(secret)
    }

    private func keychainJSON(accessToken: String, refreshToken: String) -> String {
        jsonText([
            "claudeAiOauth": [
                "accessToken": accessToken,
                "refreshToken": refreshToken,
                "expiresAt": 1_700_000_000_000,
                "scopes": ["user:profile", "user:inference"]
            ]
        ])
    }

    private func jsonText(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func jwt(payload: [String: String]) -> String {
        let header = base64URL(#"{"alg":"none"}"#)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let payloadText = String(data: payloadData, encoding: .utf8)!
        return "\(header).\(base64URL(payloadText)).signature"
    }

    private func cursorSecret(accessToken: String) -> String {
        """
        {
          "accessToken": "\(accessToken)",
          "refreshToken": null,
          "email": null,
          "membershipType": null,
          "subscriptionStatus": null,
          "subscriptionPeriodEnd": null,
          "stateDatabasePath": null,
          "source": null
        }
        """
    }

    private func base64URL(_ text: String) -> String {
        Data(text.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }
}
