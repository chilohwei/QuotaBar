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

    private func jwt(payload: [String: String]) -> String {
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

    private func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }
}
