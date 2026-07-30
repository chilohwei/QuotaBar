import Darwin
import Foundation

// Claude refresh tokens are single-use. Detached accounts can be renewed directly; the live
// account additionally uses Claude Code's own cross-process locks plus a Keychain CAS.
extension ClaudeCodeProvider {
    struct RefreshedOAuthToken {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date?
        var refreshTokenExpiresAt: Date? = nil
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
        // Some edge responses are client-shaped rather than grant-shaped. Rerun the identical
        // request through a local JavaScript runtime before treating a 429/403 as authoritative.
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
            let refreshTokenExpiresIn = (object["refresh_token_expires_in"] as? NSNumber)?.doubleValue
                ?? (object["refresh_token_expires_in"] as? String).flatMap(Double.init)
            let now = Date()
            return RefreshedOAuthToken(
                accessToken: access,
                refreshToken: (newRefresh?.isEmpty == false) ? newRefresh! : fallbackRefreshToken,
                expiresAt: expiresIn.map { now.addingTimeInterval($0) },
                refreshTokenExpiresAt: refreshTokenExpiresIn.map { now.addingTimeInterval($0) }
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

    // MARK: - Live account renewal

    static let activeRefreshLeeway: TimeInterval = 5 * 60
    static let oauthRefreshLockHeartbeatInterval: TimeInterval = 2
    static let oauthRefreshLockStaleInterval: TimeInterval = 10
    static let oauthRefreshLockRetryCount = 5

    static func shouldRefreshActiveOAuthToken(
        _ token: ClaudeOAuthToken,
        failedAccessToken: String?,
        now: Date
    ) -> Bool {
        guard token.refreshToken != nil else { return false }
        if let failedAccessToken {
            return token.accessToken == failedAccessToken
        }
        guard let expiresAt = token.expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(activeRefreshLeeway)
    }

    /// Mirrors Claude Code 2.1.x's secure-storage directory semantics. XDG_CONFIG_HOME is not
    /// part of this path: the CLI uses CLAUDE_SECURESTORAGE_CONFIG_DIR, then CLAUDE_CONFIG_DIR,
    /// then ~/.claude.
    static func claudeSecureStorageDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let defaultPath = homeDirectory.appendingPathComponent(".claude", isDirectory: true).path
        let path: String
        if let explicit = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            path = explicit.isEmpty ? defaultPath : explicit
        } else if let explicit = environment["CLAUDE_CONFIG_DIR"], !explicit.isEmpty {
            path = explicit
        } else {
            path = defaultPath
        }
        return URL(fileURLWithPath: path.precomposedStringWithCanonicalMapping, isDirectory: true)
            .standardizedFileURL
    }

    /// `proper-lockfile` is given the secure-storage directory with an explicit
    /// `.oauth_refresh.lock`, then a legacy target whose explicit lock path is
    /// `<real secure-storage path>.lock`.
    static func claudeOAuthRefreshLockPaths(secureStorageDirectory: URL) -> [URL] {
        let realDirectory = secureStorageDirectory.resolvingSymlinksInPath().standardizedFileURL
        return [
            realDirectory.appendingPathComponent(".oauth_refresh.lock", isDirectory: true),
            URL(fileURLWithPath: realDirectory.path + ".lock", isDirectory: true)
        ]
    }

    func refreshActiveStoredCredentials(
        _ stored: ClaudeCodeCredentials,
        failedAccessToken: String? = nil,
        now: Date = Date()
    ) async throws -> ClaudeCodeCredentials? {
        let secureStorageDirectory = Self.claudeSecureStorageDirectoryURL()
        var lease: ClaudeOAuthRefreshLease?
        for attempt in 0 ... Self.oauthRefreshLockRetryCount {
            lease = ClaudeOAuthRefreshLease.acquire(
                secureStorageDirectory: secureStorageDirectory,
                heartbeatInterval: Self.oauthRefreshLockHeartbeatInterval,
                staleInterval: Self.oauthRefreshLockStaleInterval
            )
            if lease != nil {
                break
            }
            guard attempt < Self.oauthRefreshLockRetryCount else { return nil }
            let delay = Double.random(in: 1 ... 2)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard let lease else { return nil }
        defer { lease.release() }

        return try await refreshActiveStoredCredentialsLocked(
            stored,
            failedAccessToken: failedAccessToken,
            now: now,
            readLiveKeychain: {
                try readClaudeCodeKeychainCredentials()
            },
            compareAndSwapLiveKeychain: { expected, replacement in
                guard lease.isValid else { return false }
                return try compareAndSwapClaudeCodeKeychainCredentials(
                    expected: expected,
                    replacement: replacement
                )
            },
            requestRefresh: { refreshToken, scopes in
                guard lease.isValid else {
                    throw OAuthUsageFetchError.invalidResponse
                }
                return try await requestTokenRefresh(refreshToken: refreshToken, scopes: scopes)
            }
        )
    }

    /// Testable lock-held core. The first same-value CAS is a no-UI writeability preflight;
    /// the second installs and verifies the rotated pair. Both compare the complete JSON value.
    func refreshActiveStoredCredentialsLocked(
        _ stored: ClaudeCodeCredentials,
        failedAccessToken: String?,
        now: Date,
        readLiveKeychain: () throws -> String?,
        compareAndSwapLiveKeychain: (_ expected: String, _ replacement: String) throws -> Bool,
        requestRefresh: (_ refreshToken: String, _ scopes: [String]?) async throws -> RefreshedOAuthToken
    ) async throws -> ClaudeCodeCredentials? {
        guard shouldFetchOAuthUsage(stored),
              let expectedToken = parseOAuthToken(from: stored),
              let liveKeychain = try readLiveKeychain(),
              let liveToken = parseOAuthToken(fromJSONText: liveKeychain),
              liveToken.accessToken == expectedToken.accessToken,
              liveToken.refreshToken == expectedToken.refreshToken,
              Self.shouldRefreshActiveOAuthToken(
                  liveToken,
                  failedAccessToken: failedAccessToken,
                  now: now
              ),
              let refreshToken = liveToken.refreshToken else {
            return nil
        }

        // Do not consume the shared, single-use refresh token unless this process can silently
        // update the exact live Keychain item while the CLI's refresh locks are held.
        guard try compareAndSwapLiveKeychain(liveKeychain, liveKeychain) else {
            return nil
        }

        let refreshed = try await requestRefresh(refreshToken, liveToken.scopes)
        var liveStored = stored
        liveStored = ClaudeCodeCredentials(
            loggedIn: liveStored.loggedIn,
            authMethod: liveStored.authMethod,
            apiProvider: liveStored.apiProvider,
            userID: liveStored.userID,
            claudeExecutablePath: liveStored.claudeExecutablePath,
            keychainCredentials: liveKeychain,
            authStatusJSON: liveStored.authStatusJSON,
            claudeSettingsJSON: liveStored.claudeSettingsJSON,
            claudeJSON: liveStored.claudeJSON,
            claudeCredentialsJSON: liveStored.claudeCredentialsJSON,
            claudeAuthJSON: liveStored.claudeAuthJSON
        )
        guard let updated = replacingOAuthToken(in: liveStored, with: refreshed),
              let replacement = updated.keychainCredentials,
              try compareAndSwapLiveKeychain(liveKeychain, replacement) else {
            throw OAuthUsageFetchError.invalidResponse
        }
        return updated
    }

    // MARK: - Detached stored-account renewal

    /// Renews the token pair of a stored account the CLI is no longer signed into. Such a pair
    /// exists nowhere but in QuotaBar's own store — logging the CLI into another account
    /// overwrote the keychain copy — so rotating it races nobody. Never touches the keychain,
    /// which belongs to whichever account the CLI is using. Returns the stored credentials with
    /// the fresh pair embedded, or nil when nothing needed doing (also on failure, where a
    /// per-pair backoff marker keeps the retry cadence honest).
    func refreshDetachedStoredCredentials(
        _ stored: ClaudeCodeCredentials,
        liveKeychainCredentials: String?,
        force: Bool = false,
        now: Date = Date()
    ) async -> ClaudeCodeCredentials? {
        await refreshDetachedStoredCredentials(
            stored,
            liveKeychainCredentials: liveKeychainCredentials,
            force: force,
            now: now,
            requestRefresh: { refreshToken, scopes in
                try await requestTokenRefresh(refreshToken: refreshToken, scopes: scopes)
            }
        )
    }

    func refreshDetachedStoredCredentials(
        _ stored: ClaudeCodeCredentials,
        liveKeychainCredentials: String?,
        force: Bool,
        now: Date,
        requestRefresh: (String, [String]?) async throws -> RefreshedOAuthToken
    ) async -> ClaudeCodeCredentials? {
        guard shouldFetchOAuthUsage(stored),
              let token = parseOAuthToken(from: stored),
              force || token.isHardExpired,
              let refreshToken = token.refreshToken else {
            return nil
        }
        // The same pair sitting in the keychain means the CLI (or the keychain self-refresh
        // path) owns the rotation; consuming the shared single-use refresh token here would
        // log that side out.
        if let liveToken = parseOAuthToken(fromJSONText: liveKeychainCredentials),
           liveToken.accessToken == token.accessToken {
            return nil
        }

        let blockPath = detachedRefreshBlockPath(refreshToken: refreshToken)
        if let blockedUntil = refreshBlockedUntil(atPath: blockPath), blockedUntil > now {
            return nil
        }

        do {
            let refreshed = try await requestRefresh(refreshToken, token.scopes)
            try? fileService.removeItemIfExists(at: blockPath)
            return replacingOAuthToken(in: stored, with: refreshed)
        } catch OAuthUsageFetchError.unauthorized {
            setRefreshBlock(atPath: blockPath, until: now.addingTimeInterval(Self.detachedRefreshDeadGrantRetryFloor))
            return nil
        } catch OAuthUsageFetchError.rateLimited(let retryAfter) {
            let floor = now.addingTimeInterval(Self.detachedRefreshRetryFloor)
            setRefreshBlock(atPath: blockPath, until: max(retryAfter ?? .distantPast, floor))
            return nil
        } catch {
            setRefreshBlock(atPath: blockPath, until: now.addingTimeInterval(Self.detachedRefreshRetryFloor))
            return nil
        }
    }

    /// Embeds a rotated token pair into the stored credentials' own copies of the credential
    /// artifacts (keychain text and, when present, `.credentials.json` text).
    func replacingOAuthToken(
        in credentials: ClaudeCodeCredentials,
        with refreshed: RefreshedOAuthToken
    ) -> ClaudeCodeCredentials? {
        let updatedKeychain = credentials.keychainCredentials.flatMap {
            replacingOAuthTokenFields(inJSONText: $0, with: refreshed)
        }
        let updatedCredentialsJSON = credentials.claudeCredentialsJSON.flatMap {
            replacingOAuthTokenFields(inJSONText: $0, with: refreshed)
        }
        guard updatedKeychain != nil || updatedCredentialsJSON != nil else {
            return nil
        }
        return ClaudeCodeCredentials(
            loggedIn: credentials.loggedIn,
            authMethod: credentials.authMethod,
            apiProvider: credentials.apiProvider,
            userID: credentials.userID,
            claudeExecutablePath: credentials.claudeExecutablePath,
            keychainCredentials: updatedKeychain ?? credentials.keychainCredentials,
            authStatusJSON: credentials.authStatusJSON,
            claudeSettingsJSON: credentials.claudeSettingsJSON,
            claudeJSON: credentials.claudeJSON,
            claudeCredentialsJSON: updatedCredentialsJSON ?? credentials.claudeCredentialsJSON,
            claudeAuthJSON: credentials.claudeAuthJSON
        )
    }

    func replacingOAuthTokenFields(inJSONText text: String, with refreshed: RefreshedOAuthToken) -> String? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var full = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var oauth = full["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        oauth["accessToken"] = refreshed.accessToken
        oauth["refreshToken"] = refreshed.refreshToken
        if let expiresAt = refreshed.expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        if let refreshTokenExpiresAt = refreshed.refreshTokenExpiresAt {
            oauth["refreshTokenExpiresAt"] = Int(refreshTokenExpiresAt.timeIntervalSince1970 * 1000)
        }
        full["claudeAiOauth"] = oauth
        guard let newData = try? JSONSerialization.data(withJSONObject: full) else { return nil }
        return String(data: newData, encoding: .utf8)
    }

    /// Backoff marker per token pair (the keychain self-refresh marker below is machine-global,
    /// which would let one account's dead grant silence every other account's renewal).
    func detachedRefreshBlockPath(refreshToken: String) -> String {
        AppPaths.quotaCacheDirectory
            .appendingPathComponent("claude-detached-refresh-block-v2-\(stableCredentialFingerprint(refreshToken))")
            .path
    }

    func refreshBlockedUntil(atPath path: String) -> Date? {
        guard let text = try? fileService.readText(at: path),
              let epoch = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    func setRefreshBlock(atPath path: String, until: Date) {
        try? fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        try? fileService.writeText(
            String(until.timeIntervalSince1970),
            to: path,
            permissions: 0o600
        )
    }

}

final class ClaudeOAuthRefreshLease: @unchecked Sendable {
    private struct OwnedLock {
        let url: URL
        let fileNumber: UInt64
    }

    private let ownedLocks: [OwnedLock]
    private let heartbeatTimer: DispatchSourceTimer
    private let stateLock = NSLock()
    private var isReleased = false

    private init(ownedLocks: [OwnedLock], heartbeatInterval: TimeInterval) {
        self.ownedLocks = ownedLocks
        heartbeatTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        heartbeatTimer.schedule(
            deadline: .now() + heartbeatInterval,
            repeating: heartbeatInterval
        )
        heartbeatTimer.setEventHandler { [weak self] in
            self?.touchOwnedLocks()
        }
        heartbeatTimer.resume()
    }

    static func acquire(
        secureStorageDirectory: URL,
        heartbeatInterval: TimeInterval,
        staleInterval: TimeInterval,
        now: Date = Date()
    ) -> ClaudeOAuthRefreshLease? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: secureStorageDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        var owned: [OwnedLock] = []
        for url in ClaudeCodeProvider.claudeOAuthRefreshLockPaths(
            secureStorageDirectory: secureStorageDirectory
        ) {
            guard let lock = createOwnedLock(
                at: url,
                staleInterval: staleInterval,
                now: now,
                fileManager: fileManager
            ) else {
                release(owned, fileManager: fileManager)
                return nil
            }
            owned.append(lock)
        }
        return ClaudeOAuthRefreshLease(
            ownedLocks: owned,
            heartbeatInterval: heartbeatInterval
        )
    }

    func release() {
        stateLock.lock()
        guard !isReleased else {
            stateLock.unlock()
            return
        }
        isReleased = true
        heartbeatTimer.cancel()
        stateLock.unlock()
        Self.release(ownedLocks, fileManager: .default)
    }

    var isValid: Bool {
        stateLock.lock()
        let active = !isReleased
        stateLock.unlock()
        guard active else { return false }
        let fileManager = FileManager.default
        return ownedLocks.allSatisfy {
            Self.fileNumber(at: $0.url, fileManager: fileManager) == $0.fileNumber
        }
    }

    deinit {
        release()
    }

    private func touchOwnedLocks() {
        stateLock.lock()
        let shouldTouch = !isReleased
        stateLock.unlock()
        guard shouldTouch else { return }

        let fileManager = FileManager.default
        for owned in ownedLocks where Self.fileNumber(at: owned.url, fileManager: fileManager) == owned.fileNumber {
            try? fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: owned.url.path
            )
        }
    }

    private static func release(_ locks: [OwnedLock], fileManager: FileManager) {
        for owned in locks.reversed()
            where fileNumber(at: owned.url, fileManager: fileManager) == owned.fileNumber {
            try? fileManager.removeItem(at: owned.url)
        }
    }

    private static func fileNumber(at url: URL, fileManager: FileManager) -> UInt64? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private static func createOwnedLock(
        at url: URL,
        staleInterval: TimeInterval,
        now: Date,
        fileManager: FileManager
    ) -> OwnedLock? {
        if url.path.withCString({ Darwin.mkdir($0, 0o700) }) != 0 {
            guard errno == EEXIST,
                  removeStaleLock(
                      at: url,
                      staleInterval: staleInterval,
                      now: now,
                      fileManager: fileManager
                  ),
                  url.path.withCString({ Darwin.mkdir($0, 0o700) }) == 0 else {
                return nil
            }
        }
        guard let fileNumber = fileNumber(at: url, fileManager: fileManager) else {
            _ = url.path.withCString { Darwin.rmdir($0) }
            return nil
        }
        return OwnedLock(url: url, fileNumber: fileNumber)
    }

    private static func removeStaleLock(
        at url: URL,
        staleInterval: TimeInterval,
        now: Date,
        fileManager: FileManager
    ) -> Bool {
        guard let first = lockMetadata(at: url, fileManager: fileManager),
              now.timeIntervalSince(first.modificationDate) > staleInterval,
              let second = lockMetadata(at: url, fileManager: fileManager),
              first == second else {
            return false
        }
        return url.path.withCString { Darwin.rmdir($0) } == 0
    }

    private struct LockMetadata: Equatable {
        let fileNumber: UInt64
        let modificationDate: Date
    }

    private static func lockMetadata(at url: URL, fileManager: FileManager) -> LockMetadata? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return LockMetadata(fileNumber: fileNumber, modificationDate: modificationDate)
    }
}
