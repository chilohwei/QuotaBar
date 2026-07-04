import CryptoKit
import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Cursor OAuth login")
struct CursorProviderOAuthLoginTests {
    @Test("OAuth session challenge is the base64url SHA-256 of the verifier")
    func oauthSessionChallengeMatchesVerifier() {
        let provider = CursorProvider()
        let session = provider.makeCursorOAuthLoginSession()

        let expectedChallenge = provider.base64URLEncodedString(
            Data(SHA256.hash(data: Data(session.verifier.utf8)))
        )

        #expect(session.challenge == expectedChallenge)
        #expect(!session.verifier.isEmpty)
        #expect(UUID(uuidString: session.uuid) != nil)
        #expect(!session.verifier.contains("+"))
        #expect(!session.verifier.contains("/"))
        #expect(!session.verifier.contains("="))
    }

    @Test("OAuth login page URL carries challenge, uuid and login mode")
    func oauthLoginPageURLCarriesSessionParameters() throws {
        let provider = CursorProvider()
        let session = CursorProvider.CursorOAuthLoginSession(
            uuid: "0f9a8b7c-1234-4abc-9def-0123456789ab",
            verifier: "test-verifier",
            challenge: "test-challenge"
        )

        let url = try #require(provider.cursorOAuthLoginPageURL(session: session))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.host == "www.cursor.com")
        #expect(components.path == "/loginDeepControl")
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )
        #expect(query["challenge"] == "test-challenge")
        #expect(query["uuid"] == session.uuid)
        #expect(query["mode"] == "login")
    }

    @Test("Poll payload with tokens becomes Cursor credentials")
    func pollPayloadWithTokensBecomesCredentials() throws {
        let provider = CursorProvider()
        let payload = Data("""
        {
          "accessToken": "access-token-value",
          "refreshToken": "refresh-token-value",
          "authId": "auth0|user_123"
        }
        """.utf8)

        let credentials = try #require(provider.cursorOAuthCredentials(fromPollData: payload))

        #expect(credentials.accessToken == "access-token-value")
        #expect(credentials.refreshToken == "refresh-token-value")
        #expect(credentials.source == "cursorOAuth")
    }

    @Test("Poll payload without an access token is treated as pending")
    func pollPayloadWithoutAccessTokenIsPending() {
        let provider = CursorProvider()

        #expect(provider.cursorOAuthCredentials(fromPollData: Data("{}".utf8)) == nil)
        #expect(provider.cursorOAuthCredentials(fromPollData: Data(#"{"accessToken": "  "}"#.utf8)) == nil)
        #expect(provider.cursorOAuthCredentials(fromPollData: Data("not-json".utf8)) == nil)
    }

    @Test("OAuth credentials survive an encode/parse roundtrip")
    func oauthCredentialsRoundtrip() throws {
        let provider = CursorProvider()
        let payload = Data("""
        {
          "accessToken": "\(jwt(claims: ["sub": "auth0|user_01"]))",
          "refreshToken": "oauth-refresh-token",
          "authId": "auth0|user_01"
        }
        """.utf8)

        let credentials = try #require(provider.cursorOAuthCredentials(fromPollData: payload))
        let parsed = try provider.parseCredentials(provider.encodeCredentials(credentials))

        #expect(parsed.accessToken == credentials.accessToken)
        #expect(parsed.refreshToken == "oauth-refresh-token")
        #expect(parsed.source == "cursorOAuth")
    }

    @Test("OAuth token refresh triggers only near expiry and with a refresh token")
    func oauthTokenRefreshTiming() {
        let provider = CursorProvider()

        func credentials(expInterval: TimeInterval?, refreshToken: String?) -> CursorProvider.CursorCredentials {
            var claims: [String: Any] = ["sub": "auth0|user_01"]
            if let expInterval {
                claims["exp"] = Date().addingTimeInterval(expInterval).timeIntervalSince1970
            }
            return CursorProvider.CursorCredentials(
                accessToken: jwt(claims: claims),
                refreshToken: refreshToken,
                email: nil,
                membershipType: nil,
                subscriptionStatus: nil,
                subscriptionPeriodEnd: nil,
                stateDatabasePath: nil,
                source: "cursorOAuth"
            )
        }

        // Fresh token: no refresh needed.
        #expect(!provider.shouldRefreshAccessToken(credentials(expInterval: 3600, refreshToken: "r")))
        // Expiring within ten minutes: refresh.
        #expect(provider.shouldRefreshAccessToken(credentials(expInterval: 120, refreshToken: "r")))
        // No refresh token available: never attempt.
        #expect(!provider.shouldRefreshAccessToken(credentials(expInterval: 120, refreshToken: nil)))
        // No exp claim: nothing to compare against.
        #expect(!provider.shouldRefreshAccessToken(credentials(expInterval: nil, refreshToken: "r")))
    }

    @Test("OAuth credentials produce stable identity aliases for dedup")
    func oauthCredentialsIdentityAliases() {
        let provider = CursorProvider()
        let secret = provider.encodeCredentials(
            CursorProvider.CursorCredentials(
                accessToken: jwt(claims: ["sub": "auth0|user_01"]),
                refreshToken: "oauth-refresh-token-stable",
                email: "oauth-user@example.com",
                membershipType: nil,
                subscriptionStatus: nil,
                subscriptionPeriodEnd: nil,
                stateDatabasePath: nil,
                source: "cursorOAuth"
            )
        )

        let aliases = provider.accountIdentityAliases(from: secret)

        #expect(aliases.contains("cursor:sub:auth0|user_01"))
        #expect(aliases.contains("cursor:email:oauth-user@example.com"))
    }

    private func jwt(claims: [String: Any]) -> String {
        let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
        let payloadData = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        return "\(header).\(base64URL(payloadData)).signature"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
