import Foundation

// Self-renewal of a lapsed Claude Code keychain token.
//
// QuotaBar treats Claude Code as the owner of these credentials and never races it for the
// single-use refresh token: rotating the pair while the CLI is maintaining it invalidates the
// copy the CLI holds and logs the user out — the ping-pong that once forced re-logins several
// times a day. But the owner doesn't always show up: GUI clients (the Claude Code desktop app)
// keep their own credential store and never renew this keychain item, and `claude auth status`
// merely reports state without refreshing. Left alone, the keychain token dies 8 hours after
// the last CLI use and QuotaBar is stuck on cached data.
//
// So the policy is: give the CLI first claim, then take over. Only once the token has sat
// hard-expired past `selfRefreshGrace` — proof no CLI is actively maintaining it — QuotaBar
// renews the pair against the exact credentials currently in the keychain and immediately
// writes the rotated pair back, so the CLI's next launch rides the fresh token just like
// QuotaBar rides its own.
//
// The renewal itself mirrors the CLI's request exactly (platform.claude.com endpoint, granted
// scopes in the body) and, when the CDN edge still rejects URLSession's TLS signature with a
// 429/403, retries once through a local Node/Bun runtime — the client class the edge is known
// to accept, since the CLI itself is one.
extension ClaudeCodeProvider {
    struct RefreshedOAuthToken {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date?
    }

    /// Renews the keychain token pair when it has lapsed with no other maintainer in sight.
    /// Returns a usable access token — freshly rotated, or the keychain's own if some other
    /// maintainer beat us to the renewal — or nil when the fallback note should stay.
    func selfRefreshHardExpiredToken(
        matching expired: ClaudeOAuthToken,
        intent: RefreshIntent,
        now: Date = Date()
    ) async -> ClaudeOAuthToken? {
        guard Self.shouldAttemptSelfRefresh(
            expiresAt: expired.expiresAt,
            blockedUntil: selfRefreshBlockedUntil(),
            intent: intent,
            now: now
        ) else {
            return nil
        }

        // Rotate only the exact pair sitting in the keychain right now. The live re-read both
        // picks up a token some other maintainer just minted (ride it, no rotation) and
        // guarantees we never consume a refresh token from a stale stored copy.
        guard let live = parseOAuthToken(fromJSONText: try? readClaudeCodeKeychainCredentials()) else {
            return nil
        }
        if !live.isHardExpired {
            return live
        }
        guard live.accessToken == expired.accessToken,
              let refreshToken = live.refreshToken else {
            // The keychain holds a different (also expired) pair than the one this fetch started
            // from — likely another account was activated mid-flight. Not ours to rotate.
            return nil
        }

        do {
            let refreshed = try await requestTokenRefresh(refreshToken: refreshToken, scopes: live.scopes)
            // Write-back must not be skipped: the old refresh token is consumed the moment the
            // endpoint answers, so a keychain still holding it would strand the CLI. If the write
            // fails there is nothing better to do than still use the fresh token for this fetch.
            try? writeRefreshedOAuthToken(refreshed)
            clearSelfRefreshBlock()
            return ClaudeOAuthToken(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: refreshed.expiresAt
            )
        } catch OAuthUsageFetchError.unauthorized {
            setSelfRefreshBlock(until: now.addingTimeInterval(Self.selfRefreshDeadGrantRetryFloor))
            return nil
        } catch OAuthUsageFetchError.rateLimited(let retryAfter) {
            // A rate-limited endpoint stays rate-limited if we knock every ten minutes; honor
            // its own deadline when it names one longer than the floor.
            let floor = now.addingTimeInterval(Self.selfRefreshRetryFloor)
            setSelfRefreshBlock(until: max(retryAfter ?? .distantPast, floor))
            return nil
        } catch {
            setSelfRefreshBlock(until: now.addingTimeInterval(Self.selfRefreshRetryFloor))
            return nil
        }
    }

    /// Pure gate for `selfRefreshHardExpiredToken`: expired past the grace window, and not inside
    /// a failure-backoff window (manual refreshes bypass the backoff, never the grace — the grace
    /// is what keeps QuotaBar from stealing an in-flight CLI rotation).
    static func shouldAttemptSelfRefresh(
        expiresAt: Date?,
        blockedUntil: Date?,
        intent: RefreshIntent,
        now: Date = Date()
    ) -> Bool {
        guard let expiresAt, now.timeIntervalSince(expiresAt) >= selfRefreshGrace else {
            return false
        }
        if intent.bypassesAppBackoff {
            return true
        }
        if let blockedUntil, blockedUntil > now {
            return false
        }
        return true
    }

    func requestTokenRefresh(refreshToken: String, scopes: [String]?) async throws -> RefreshedOAuthToken {
        let body = try Self.tokenRefreshRequestBody(refreshToken: refreshToken, scopes: scopes)
        let direct = try await postTokenRefresh(body: body)
        guard Self.isLikelyEdgeBlock(statusCode: direct.statusCode) else {
            return try Self.parseTokenRefreshResponse(
                statusCode: direct.statusCode,
                data: direct.data,
                retryAfter: direct.retryAfter,
                fallbackRefreshToken: refreshToken
            )
        }
        // Cloudflare fingerprints the TLS client on this endpoint: URLSession's signature can be
        // throttled or blocked outright (HTTP 429/403 even for a perfectly valid grant) while
        // Claude Code's own Node-based stack passes. Rerun the identical request through a local
        // JavaScript runtime before believing the edge's answer.
        guard let viaRuntime = try? await postTokenRefreshViaJavaScriptRuntime(body: body) else {
            return try Self.parseTokenRefreshResponse(
                statusCode: direct.statusCode,
                data: direct.data,
                retryAfter: direct.retryAfter,
                fallbackRefreshToken: refreshToken
            )
        }
        return try Self.parseTokenRefreshResponse(
            statusCode: viaRuntime.statusCode,
            data: viaRuntime.data,
            retryAfter: nil,
            fallbackRefreshToken: refreshToken
        )
    }

    static func tokenRefreshRequestBody(refreshToken: String, scopes: [String]?) throws -> Data {
        let effectiveScopes = (scopes?.isEmpty == false) ? scopes! : oauthDefaultRefreshScopes
        return try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
            "scope": effectiveScopes.joined(separator: " ")
        ])
    }

    /// Statuses the CDN edge produces when it dislikes the client rather than the grant:
    /// worth one retry through a runtime whose TLS signature it accepts.
    static func isLikelyEdgeBlock(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 403
    }

    struct TokenRefreshTransportResponse {
        let statusCode: Int
        let data: Data
        var retryAfter: Date? = nil
    }

    private func postTokenRefresh(body: Data) async throws -> TokenRefreshTransportResponse {
        var request = URLRequest(url: Self.oauthTokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.oauthUsageUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (data, response) = try await Self.liveSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthUsageFetchError.invalidResponse
        }
        return TokenRefreshTransportResponse(
            statusCode: http.statusCode,
            data: data,
            retryAfter: QuotaHTTPClient.retryAfterDeadline(from: http)
        )
    }

    static func parseTokenRefreshResponse(
        statusCode: Int,
        data: Data,
        retryAfter: Date?,
        fallbackRefreshToken: String
    ) throws -> RefreshedOAuthToken {
        switch statusCode {
        case 200:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = (object["access_token"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !access.isEmpty else {
                throw OAuthUsageFetchError.invalidResponse
            }
            let newRefresh = (object["refresh_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue
                ?? (object["expires_in"] as? String).flatMap(Double.init)
            let expiresAt = expiresIn.map { Date().addingTimeInterval($0) }
            return RefreshedOAuthToken(
                accessToken: access,
                refreshToken: (newRefresh?.isEmpty == false) ? newRefresh! : fallbackRefreshToken,
                expiresAt: expiresAt
            )
        case 400:
            // OAuth error responses use 400 for permanently dead grants (RFC 6749 §5.2).
            if isPermanentTokenRefreshFailure(body: data) {
                throw OAuthUsageFetchError.unauthorized
            }
            throw OAuthUsageFetchError.httpStatus(statusCode)
        case 401:
            throw OAuthUsageFetchError.unauthorized
        case 403:
            // Dead grants answer 400 here; a 403 is the edge rejecting the client. Transient —
            // must not trip the dead-grant backoff that waits a day.
            throw OAuthUsageFetchError.httpStatus(statusCode)
        case 429:
            throw OAuthUsageFetchError.rateLimited(retryAfter: retryAfter)
        default:
            throw OAuthUsageFetchError.httpStatus(statusCode)
        }
    }

    static func isPermanentTokenRefreshFailure(body: Data) -> Bool {
        guard let text = String(data: body, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("invalid_grant")
            || text.contains("invalid_request")
            || text.contains("invalid refresh token")
    }

    // MARK: - JavaScript-runtime transport

    // Node/Bun are the TLS stacks the token endpoint's edge demonstrably accepts (they are what
    // Claude Code itself is built on). The POST payload travels over stdin so the refresh token
    // never appears in an argv the whole machine can read.
    func postTokenRefreshViaJavaScriptRuntime(body: Data) async throws -> TokenRefreshTransportResponse {
        guard let runtime = Self.javaScriptRuntimeExecutableURL() else {
            throw OAuthUsageFetchError.invalidResponse
        }
        let output = try await runProcessWithInput(
            executable: runtime,
            arguments: ["-e", Self.javaScriptTokenRefreshScript],
            input: body,
            timeout: 35
        )
        return try Self.parseJavaScriptTransportOutput(output)
    }

    /// Reads the POST body from stdin, relays it to the token endpoint, and prints
    /// `{"status":<code>,"body":<text>}` — status 0 signals a transport-level failure.
    static var javaScriptTokenRefreshScript: String {
        """
        let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",async()=>{\
        try{const r=await fetch("\(oauthTokenURL.absoluteString)",{method:"POST",\
        headers:{"Content-Type":"application/json","Accept":"application/json"},body:d});\
        const t=await r.text();process.stdout.write(JSON.stringify({status:r.status,body:t}))}\
        catch(e){process.stdout.write(JSON.stringify({status:0,body:String((e&&e.message)||e)}))}});
        """
    }

    static func parseJavaScriptTransportOutput(_ output: String) throws -> TokenRefreshTransportResponse {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = (object["status"] as? NSNumber)?.intValue,
              status > 0,
              let body = object["body"] as? String else {
            throw OAuthUsageFetchError.invalidResponse
        }
        return TokenRefreshTransportResponse(statusCode: status, data: Data(body.utf8))
    }

    /// First JavaScript runtime found on the machine. GUI apps inherit launchd's minimal PATH,
    /// so the usual install locations are probed explicitly, same as `claudeExecutableURL`.
    static func javaScriptRuntimeExecutableURL(fileManager: FileManager = .default) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fixedDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin"
        ]
        var candidates: [URL] = []
        for name in ["node", "bun"] {
            for directory in pathDirectories + fixedDirectories {
                candidates.append(URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
        candidates.append(contentsOf: nvmNodeCandidates(home: home, fileManager: fileManager))
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func nvmNodeCandidates(home: String, fileManager: FileManager) -> [URL] {
        let versionsDirectory = "\(home)/.nvm/versions/node"
        guard let versions = try? fileManager.contentsOfDirectory(atPath: versionsDirectory) else {
            return []
        }
        return versions
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { URL(fileURLWithPath: "\(versionsDirectory)/\($0)/bin/node") }
    }

    private func runProcessWithInput(
        executable: URL,
        arguments: [String],
        input: Data,
        timeout: TimeInterval
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(input)
        inputPipe.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                throw OAuthUsageFetchError.invalidResponse
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        guard process.terminationStatus == 0 else {
            throw OAuthUsageFetchError.invalidResponse
        }
        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Merges the rotated tokens back into the keychain credentials, preserving every other field.
    func writeRefreshedOAuthToken(_ token: RefreshedOAuthToken) throws {
        guard let text = try readClaudeCodeKeychainCredentials()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let data = text.data(using: .utf8),
              var full = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = full["claudeAiOauth"] as? [String: Any] else {
            return
        }
        oauth["accessToken"] = token.accessToken
        oauth["refreshToken"] = token.refreshToken
        if let expiresAt = token.expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        full["claudeAiOauth"] = oauth
        let newData = try JSONSerialization.data(withJSONObject: full)
        guard let newText = String(data: newData, encoding: .utf8) else { return }
        try writeClaudeCodeKeychainCredentials(newText)
    }

    // The keychain item is a single machine-global resource, so the failure backoff is one
    // global marker rather than per-account state.
    func selfRefreshBlockPath() -> String {
        AppPaths.quotaCacheDirectory.appendingPathComponent("claude-token-refresh-block").path
    }

    func selfRefreshBlockedUntil() -> Date? {
        guard let text = try? fileService.readText(at: selfRefreshBlockPath()),
              let epoch = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    func setSelfRefreshBlock(until: Date) {
        try? fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        try? fileService.writeText(
            String(until.timeIntervalSince1970),
            to: selfRefreshBlockPath(),
            permissions: 0o600
        )
    }

    func clearSelfRefreshBlock() {
        try? fileService.removeItemIfExists(at: selfRefreshBlockPath())
    }
}
