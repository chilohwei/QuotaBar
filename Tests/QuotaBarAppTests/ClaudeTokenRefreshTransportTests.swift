import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Claude token refresh transport")
struct ClaudeTokenRefreshTransportTests {
    @Test("refresh body mirrors the CLI grant exactly")
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
        #expect(object["expires_in"] == nil)
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
            data: Data(
                #"{"access_token":"a2","refresh_token":"r2","expires_in":28800,"refresh_token_expires_in":31536000}"#.utf8
            ),
            retryAfter: nil,
            fallbackRefreshToken: "r1"
        )
        #expect(rotated.accessToken == "a2")
        #expect(rotated.refreshToken == "r2")
        let expiresAt = try #require(rotated.expiresAt)
        #expect(abs(expiresAt.timeIntervalSinceNow - 28800) < 60)
        let refreshTokenExpiresAt = try #require(rotated.refreshTokenExpiresAt)
        #expect(abs(refreshTokenExpiresAt.timeIntervalSinceNow - 31_536_000) < 60)

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
        guard case .httpStatus(400) = failure(status: 400, body: #"{"error":"invalid_request"}"#) else {
            Issue.record("generic invalid_request should remain retryable")
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

    @Test("active refresh follows the CLI five-minute threshold and force CAS")
    func activeRefreshThresholdAndForceCAS() async throws {
        let provider = ClaudeCodeProvider()
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        func credentials(access: String, expiresAt: Date) -> ClaudeCodeProvider.ClaudeCodeCredentials {
            let json = """
            {"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"r1","expiresAt":\(Int(expiresAt.timeIntervalSince1970 * 1000))}}
            """
            return ClaudeCodeProvider.ClaudeCodeCredentials(
                loggedIn: true,
                authMethod: "oauth",
                apiProvider: "firstParty",
                userID: nil,
                claudeExecutablePath: nil,
                keychainCredentials: json,
                authStatusJSON: nil,
                claudeSettingsJSON: nil,
                claudeJSON: nil,
                claudeCredentialsJSON: nil,
                claudeAuthJSON: nil
            )
        }

        let outsideLeeway = try #require(provider.parseOAuthToken(
            from: credentials(access: "a1", expiresAt: now.addingTimeInterval(301))
        ))
        #expect(!ClaudeCodeProvider.shouldRefreshActiveOAuthToken(
            outsideLeeway,
            failedAccessToken: nil,
            now: now
        ))
        #expect(ClaudeCodeProvider.shouldRefreshActiveOAuthToken(
            outsideLeeway,
            failedAccessToken: "a1",
            now: now
        ))
        #expect(!ClaudeCodeProvider.shouldRefreshActiveOAuthToken(
            outsideLeeway,
            failedAccessToken: "different",
            now: now
        ))

        let expiring = credentials(access: "a1", expiresAt: now.addingTimeInterval(300))
        let live = try #require(expiring.keychainCredentials)
        var swaps: [(String, String)] = []
        var refreshRequests = 0
        let refreshed = try await provider.refreshActiveStoredCredentialsLocked(
            expiring,
            failedAccessToken: nil,
            now: now,
            readLiveKeychain: { live },
            compareAndSwapLiveKeychain: { expected, replacement in
                swaps.append((expected, replacement))
                return true
            },
            requestRefresh: { refreshToken, _ in
                refreshRequests += 1
                #expect(refreshToken == "r1")
                return ClaudeCodeProvider.RefreshedOAuthToken(
                    accessToken: "a2",
                    refreshToken: "r2",
                    expiresAt: now.addingTimeInterval(28_800)
                )
            }
        )

        #expect(refreshRequests == 1)
        #expect(swaps.count == 2)
        #expect(swaps[0].0 == live)
        #expect(swaps[0].1 == live)
        let refreshedCredentials = try #require(refreshed)
        #expect(try #require(provider.parseOAuthToken(from: refreshedCredentials)).accessToken == "a2")
    }

    @Test("active refresh never spends a token after a failed CAS or live rotation")
    func activeRefreshRequiresExactLiveCAS() async throws {
        let provider = ClaudeCodeProvider()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let storedJSON = """
        {"claudeAiOauth":{"accessToken":"a1","refreshToken":"r1","expiresAt":\(Int(now.timeIntervalSince1970 * 1000))}}
        """
        let stored = ClaudeCodeProvider.ClaudeCodeCredentials(
            loggedIn: true,
            authMethod: "oauth",
            apiProvider: "firstParty",
            userID: nil,
            claudeExecutablePath: nil,
            keychainCredentials: storedJSON,
            authStatusJSON: nil,
            claudeSettingsJSON: nil,
            claudeJSON: nil,
            claudeCredentialsJSON: nil,
            claudeAuthJSON: nil
        )
        let rotatedLive = """
        {"claudeAiOauth":{"accessToken":"other","refreshToken":"other-r","expiresAt":\(Int(now.timeIntervalSince1970 * 1000))}}
        """
        var refreshRequests = 0

        let changed = try await provider.refreshActiveStoredCredentialsLocked(
            stored,
            failedAccessToken: nil,
            now: now,
            readLiveKeychain: { rotatedLive },
            compareAndSwapLiveKeychain: { _, _ in
                Issue.record("CAS must not run after the live pair changed")
                return true
            },
            requestRefresh: { _, _ in
                refreshRequests += 1
                throw OAuthUsageFetchError.invalidResponse
            }
        )
        #expect(changed == nil)

        let preflightFailed = try await provider.refreshActiveStoredCredentialsLocked(
            stored,
            failedAccessToken: "a1",
            now: now,
            readLiveKeychain: { storedJSON },
            compareAndSwapLiveKeychain: { _, _ in false },
            requestRefresh: { _, _ in
                refreshRequests += 1
                throw OAuthUsageFetchError.invalidResponse
            }
        )
        #expect(preflightFailed == nil)
        #expect(refreshRequests == 0)
    }

    @Test("Claude OAuth lock paths match the CLI secure-storage contract")
    func claudeOAuthLockPaths() {
        let home = URL(fileURLWithPath: "/tmp/quota-home", isDirectory: true)
        let defaultDirectory = ClaudeCodeProvider.claudeSecureStorageDirectoryURL(
            environment: ["XDG_CONFIG_HOME": "/ignored"],
            homeDirectory: home
        )
        #expect(defaultDirectory.path == "/tmp/quota-home/.claude")

        let customDirectory = ClaudeCodeProvider.claudeSecureStorageDirectoryURL(
            environment: [
                "CLAUDE_CONFIG_DIR": "/tmp/custom-claude",
                "XDG_CONFIG_HOME": "/ignored"
            ],
            homeDirectory: home
        )
        #expect(customDirectory.path == "/tmp/custom-claude")
        let paths = ClaudeCodeProvider.claudeOAuthRefreshLockPaths(
            secureStorageDirectory: customDirectory
        )
        #expect(paths.map(\.path) == [
            "/tmp/custom-claude/.oauth_refresh.lock",
            "/tmp/custom-claude.lock"
        ])

        let emptySecureStorage = ClaudeCodeProvider.claudeSecureStorageDirectoryURL(
            environment: [
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "",
                "CLAUDE_CONFIG_DIR": "/ignored"
            ],
            homeDirectory: home
        )
        #expect(emptySecureStorage.path == "/tmp/quota-home/.claude")
    }

    @Test("stale OAuth locks recover and a replaced lock invalidates the lease")
    func staleOAuthLockRecoveryAndLeaseValidity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarClaudeLockTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let paths = ClaudeCodeProvider.claudeOAuthRefreshLockPaths(
            secureStorageDirectory: root
        )
        try FileManager.default.createDirectory(at: paths[0], withIntermediateDirectories: false)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-11)],
            ofItemAtPath: paths[0].path
        )

        let lease = try #require(ClaudeOAuthRefreshLease.acquire(
            secureStorageDirectory: root,
            heartbeatInterval: 60,
            staleInterval: 10,
            now: now
        ))
        #expect(lease.isValid)

        try FileManager.default.removeItem(at: paths[0])
        try FileManager.default.createDirectory(at: paths[0], withIntermediateDirectories: false)
        #expect(!lease.isValid)
        lease.release()
        #expect(FileManager.default.fileExists(atPath: paths[0].path))
        #expect(!FileManager.default.fileExists(atPath: paths[1].path))
    }

    @Test("a fresh OAuth lock is never stolen")
    func freshOAuthLockIsNotStolen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarClaudeFreshLockTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstPath = ClaudeCodeProvider.claudeOAuthRefreshLockPaths(
            secureStorageDirectory: root
        )[0]
        try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: false)

        let lease = ClaudeOAuthRefreshLease.acquire(
            secureStorageDirectory: root,
            heartbeatInterval: 60,
            staleInterval: 10,
            now: Date()
        )
        #expect(lease == nil)
        #expect(FileManager.default.fileExists(atPath: firstPath.path))
    }
}
