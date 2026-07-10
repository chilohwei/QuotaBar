import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Claude token refresh transport")
struct ClaudeTokenRefreshTransportTests {
    @Test("refresh body mirrors the CLI: grant, client_id, and the granted scopes")
    func refreshBodyMatchesCLIShape() throws {
        let body = try ClaudeCodeProvider.tokenRefreshRequestBody(
            refreshToken: "refresh-1",
            scopes: ["user:profile", "user:inference"]
        )
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["grant_type"] as? String == "refresh_token")
        #expect(object["refresh_token"] as? String == "refresh-1")
        #expect(object["client_id"] as? String == ClaudeCodeProvider.oauthClientID)
        #expect(object["scope"] as? String == "user:profile user:inference")
    }

    @Test("missing or empty stored scopes fall back to the CLI's default set")
    func refreshBodyDefaultScopes() throws {
        for scopes in [nil, [String]()] {
            let body = try ClaudeCodeProvider.tokenRefreshRequestBody(refreshToken: "r", scopes: scopes)
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["scope"] as? String == ClaudeCodeProvider.oauthDefaultRefreshScopes.joined(separator: " "))
        }
    }

    @Test("token endpoint moved with the CLI to platform.claude.com")
    func tokenEndpointHost() {
        #expect(ClaudeCodeProvider.oauthTokenURL.host == "platform.claude.com")
    }

    @Test("edge blocks are the fingerprint-shaped statuses only")
    func edgeBlockStatuses() {
        #expect(ClaudeCodeProvider.isLikelyEdgeBlock(statusCode: 429))
        #expect(ClaudeCodeProvider.isLikelyEdgeBlock(statusCode: 403))
        #expect(!ClaudeCodeProvider.isLikelyEdgeBlock(statusCode: 200))
        #expect(!ClaudeCodeProvider.isLikelyEdgeBlock(statusCode: 400))
        #expect(!ClaudeCodeProvider.isLikelyEdgeBlock(statusCode: 401))
        #expect(!ClaudeCodeProvider.isLikelyEdgeBlock(statusCode: 500))
    }

    @Test("a successful response rotates the pair and keeps the old refresh token when none returns")
    func successfulResponseParsing() throws {
        let rotated = try ClaudeCodeProvider.parseTokenRefreshResponse(
            statusCode: 200,
            data: Data(#"{"access_token":"a2","refresh_token":"r2","expires_in":28800}"#.utf8),
            retryAfter: nil,
            fallbackRefreshToken: "r1"
        )
        #expect(rotated.accessToken == "a2")
        #expect(rotated.refreshToken == "r2")
        let expiresAt = try #require(rotated.expiresAt)
        #expect(abs(expiresAt.timeIntervalSinceNow - 28800) < 60)

        let kept = try ClaudeCodeProvider.parseTokenRefreshResponse(
            statusCode: 200,
            data: Data(#"{"access_token":"a2"}"#.utf8),
            retryAfter: nil,
            fallbackRefreshToken: "r1"
        )
        #expect(kept.refreshToken == "r1")
    }

    @Test("dead grants map to unauthorized; an edge 403 stays a transient HTTP failure")
    func failureMapping() {
        func failure(status: Int, body: String = "") -> OAuthUsageFetchError? {
            do {
                _ = try ClaudeCodeProvider.parseTokenRefreshResponse(
                    statusCode: status,
                    data: Data(body.utf8),
                    retryAfter: nil,
                    fallbackRefreshToken: "r"
                )
                return nil
            } catch let error as OAuthUsageFetchError {
                return error
            } catch {
                return nil
            }
        }

        // 400 invalid_grant / 401: the grant itself is dead — only a fresh CLI login helps.
        guard case .unauthorized = failure(status: 400, body: #"{"error":"invalid_grant"}"#) else {
            Issue.record("400 invalid_grant should be unauthorized")
            return
        }
        guard case .unauthorized = failure(status: 401) else {
            Issue.record("401 should be unauthorized")
            return
        }
        // 403 is Cloudflare rejecting the client, not the grant: must not trip the 24h backoff.
        guard case .httpStatus(403) = failure(status: 403) else {
            Issue.record("403 should be a transient http failure")
            return
        }
        guard case .rateLimited = failure(status: 429) else {
            Issue.record("429 should be rateLimited")
            return
        }
    }

    @Test("JS runtime transport output parses status and body; transport errors are rejected")
    func javascriptTransportOutputParsing() throws {
        let ok = try ClaudeCodeProvider.parseJavaScriptTransportOutput(
            #"{"status":200,"body":"{\"access_token\":\"a\"}"}"#
        )
        #expect(ok.statusCode == 200)
        #expect(String(data: ok.data, encoding: .utf8) == #"{"access_token":"a"}"#)

        #expect(throws: (any Error).self) {
            _ = try ClaudeCodeProvider.parseJavaScriptTransportOutput(#"{"status":0,"body":"fetch failed"}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try ClaudeCodeProvider.parseJavaScriptTransportOutput("not json")
        }
    }

    @Test("stored scopes ride along on the parsed token")
    func scopesParsing() throws {
        let provider = ClaudeCodeProvider()
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","scopes":["user:profile"," user:inference ",""]}}"#
        let token = try #require(provider.parseOAuthToken(fromJSONText: json))
        #expect(token.scopes == ["user:profile", "user:inference"])

        let scopeless = #"{"claudeAiOauth":{"accessToken":"a"}}"#
        #expect(try #require(provider.parseOAuthToken(fromJSONText: scopeless)).scopes == nil)
    }
}
