import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Claude quota staleness")
struct ClaudeQuotaStalenessTests {
    private func snapshot(
        primary: QuotaWindow?,
        secondary: QuotaWindow? = nil,
        isQuotaBlocked: Bool? = nil,
        availabilityStatus: QuotaAvailabilityStatus? = nil,
        note: String? = nil,
        updatedAt: Date = Date()
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            source: "Claude Code OAuth",
            primary: primary,
            secondary: secondary,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: updatedAt,
            isQuotaBlocked: isQuotaBlocked,
            availabilityStatus: availabilityStatus,
            note: note
        )
    }

    @Test("expired windows are dropped and exhaustion flags cleared with them")
    func expiredWindowsAreDropped() {
        let now = Date()
        let expiredExhausted = QuotaWindow(label: "5h", used: 100, limit: 100, resetAt: now.addingTimeInterval(-3600))
        let freshWeekly = QuotaWindow(label: "7d", used: 38, limit: 100, resetAt: now.addingTimeInterval(86_400))

        let pruned = snapshot(
            primary: expiredExhausted,
            secondary: freshWeekly,
            isQuotaBlocked: true,
            availabilityStatus: .quotaExhausted
        ).removingExpiredWindows(now: now)

        #expect(pruned.primary == nil)
        #expect(pruned.secondary == freshWeekly)
        #expect(pruned.isQuotaBlocked == nil)
        #expect(pruned.availabilityStatus == nil)
        #expect(pruned.effectiveAvailabilityStatus == .normal)
    }

    @Test("active and reset-less windows survive pruning unchanged")
    func activeWindowsSurvive() {
        let now = Date()
        let active = QuotaWindow(label: "5h", used: 10, limit: 100, resetAt: now.addingTimeInterval(600))
        let noReset = QuotaWindow(label: "7d", used: 20, limit: 100, resetAt: nil)
        let original = snapshot(primary: active, secondary: noReset, isQuotaBlocked: false)

        #expect(original.removingExpiredWindows(now: now) == original)
    }

    @Test("exhaustion is kept when a still-active window is exhausted")
    func exhaustionKeptForActiveWindow() {
        let now = Date()
        let expired = QuotaWindow(label: "7d", used: 50, limit: 100, resetAt: now.addingTimeInterval(-3600))
        let activeExhausted = QuotaWindow(label: "5h", used: 100, limit: 100, resetAt: now.addingTimeInterval(600))

        let pruned = snapshot(
            primary: activeExhausted,
            secondary: expired,
            isQuotaBlocked: true,
            availabilityStatus: .quotaExhausted
        ).removingExpiredWindows(now: now)

        #expect(pruned.primary == activeExhausted)
        #expect(pruned.secondary == nil)
        #expect(pruned.isQuotaBlocked == true)
        #expect(pruned.availabilityStatus == .quotaExhausted)
    }

    @Test("fresh OAuth recovery does not inherit stale fallback block state")
    func mergedSnapshotRecomputesBlockStateFromSelectedWindows() {
        let provider = ClaudeCodeProvider()
        let healthyPrimary = QuotaWindow(label: "5h", used: 20, limit: 100, resetAt: nil)
        let healthySecondary = QuotaWindow(label: "7d", used: 30, limit: 100, resetAt: nil)
        let exhaustedSecondary = QuotaWindow(label: "7d", used: 100, limit: 100, resetAt: nil)
        let preferred = snapshot(
            primary: healthyPrimary,
            isQuotaBlocked: false
        )
        for (availability, note) in [
            (QuotaAvailabilityStatus.sessionRateLimited, QuotaNoteCatalog.claudeRateLimitReached),
            (.authRateLimited, QuotaNoteCatalog.claudeUsageRateLimited)
        ] {
            let staleBlockedFallback = snapshot(
                primary: nil,
                secondary: healthySecondary,
                isQuotaBlocked: true,
                availabilityStatus: availability,
                note: note
            )
            let recovered = provider.mergeClaudeSnapshot(
                preferred,
                fillingMissingMetricsFrom: staleBlockedFallback
            )
            #expect(recovered.secondary == healthySecondary)
            #expect(recovered.isQuotaBlocked == false)
            #expect(recovered.availabilityStatus == nil)
            #expect(recovered.note == nil)
            #expect(recovered.effectiveAvailabilityStatus == .normal)
        }

        let selectedExhaustedWindow = provider.mergeClaudeSnapshot(
            preferred,
            fillingMissingMetricsFrom: snapshot(primary: nil, secondary: exhaustedSecondary)
        )
        #expect(selectedExhaustedWindow.isQuotaBlocked == true)
        #expect(selectedExhaustedWindow.availabilityStatus == .quotaExhausted)
    }

    @Test("stale live fallback rejects a cache whose windows all reset")
    func staleFallbackRejectsFullyExpiredCache() {
        let provider = ClaudeCodeProvider()
        let now = Date()
        let cached = ClaudeCodeProvider.CachedClaudeUsage(
            schemaVersion: 1,
            cachedAt: now.addingTimeInterval(-300),
            snapshot: snapshot(
                primary: QuotaWindow(label: "5h", used: 100, limit: 100, resetAt: now.addingTimeInterval(-3600)),
                updatedAt: now.addingTimeInterval(-300)
            )
        )

        #expect(provider.staleLiveFallback(cached) == nil)
    }

    @Test("stale live fallback keeps a cache with an active window")
    func staleFallbackKeepsActiveCache() throws {
        let provider = ClaudeCodeProvider()
        let now = Date()
        let cached = ClaudeCodeProvider.CachedClaudeUsage(
            schemaVersion: 1,
            cachedAt: now.addingTimeInterval(-300),
            snapshot: snapshot(
                primary: QuotaWindow(label: "5h", used: 40, limit: 100, resetAt: now.addingTimeInterval(3600)),
                updatedAt: now.addingTimeInterval(-300)
            )
        )

        let fallback = try #require(provider.staleLiveFallback(cached))
        #expect(fallback.source == "Claude Code OAuth Cache")
        #expect(fallback.primary?.label == "5h")
    }

    @Test("usage rate-limit marker suppresses automatic traffic but manual refresh can retry")
    func freshUsageRateLimitMarkerSuppressesNetworkWithoutCache() {
        let provider = ClaudeCodeProvider()
        let now = Date()

        for intent in [RefreshIntent.background, .visible, .local] {
            let preflight = provider.oauthUsagePreflight(
                cached: nil,
                rateLimitMarkerIsFresh: true,
                intent: intent,
                now: now
            )
            #expect(!preflight.shouldRequestNetwork)
            #expect(preflight.snapshot == nil)
        }
        let manual = provider.oauthUsagePreflight(
            cached: nil,
            rateLimitMarkerIsFresh: true,
            intent: .manual,
            now: now
        )
        #expect(manual.shouldRequestNetwork)
        #expect(manual.snapshot == nil)
    }

    @Test("usage rate-limit deadline honors Retry-After with a polling floor")
    func usageRateLimitDeadlineHonorsServer() {
        let now = Date()
        let short = ClaudeCodeProvider.usageRateLimitDeadline(
            retryAfter: now.addingTimeInterval(30),
            now: now
        )
        let long = ClaudeCodeProvider.usageRateLimitDeadline(
            retryAfter: now.addingTimeInterval(3600),
            now: now
        )
        let unspecified = ClaudeCodeProvider.usageRateLimitDeadline(retryAfter: nil, now: now)

        #expect(short == now.addingTimeInterval(ClaudeCodeProvider.liveUsageMinFetchInterval))
        #expect(long == now.addingTimeInterval(3600))
        #expect(unspecified == now.addingTimeInterval(ClaudeCodeProvider.usageRateLimitMarkerFreshness))
    }

    @Test("local statusLine refresh never requests OAuth usage")
    func localStatusLineRefreshNeverRequestsOAuthUsage() {
        let provider = ClaudeCodeProvider()
        let preflight = provider.oauthUsagePreflight(
            cached: nil,
            rateLimitMarkerIsFresh: false,
            intent: .local,
            now: Date()
        )

        #expect(!preflight.shouldRequestNetwork)
        #expect(preflight.snapshot == nil)
    }

    @Test("OAuth usage 429 without cache does not require a later CLI event")
    func oauthUsageRateLimitWithoutCacheRemainsSelfRecovering() async throws {
        let provider = ClaudeCodeProvider()
        let credentialsJSON = """
        {
          "claudeAiOauth": {
            "accessToken": "fixture-access-token",
            "refreshToken": "fixture-refresh-token",
            "expiresAt": 4102444800000
          }
        }
        """
        let credentials = ClaudeCodeProvider.ClaudeCodeCredentials(
            loggedIn: true,
            authMethod: "oauth",
            apiProvider: "firstParty",
            userID: nil,
            claudeExecutablePath: nil,
            keychainCredentials: nil,
            authStatusJSON: nil,
            claudeSettingsJSON: nil,
            claudeJSON: nil,
            claudeCredentialsJSON: credentialsJSON,
            claudeAuthJSON: nil
        )

        let cacheKey = try #require(provider.usageCacheKey(credentials))
        defer { provider.clearUsageRateLimitMarker(cacheKey) }
        let snapshot = try await provider.fetchOAuthUsageSnapshot(
            credentials: credentials,
            intent: .background
        ) { _ in
            throw OAuthUsageFetchError.rateLimited(
                retryAfter: Date().addingTimeInterval(6 * 60 * 60)
            )
        }

        #expect(snapshot == nil)
        #expect(provider.isAuthRateLimited(credentials))
    }

    @Test("OAuth retry throttling is not misreported as invalid credentials")
    func oauthRetryRateLimitKeepsAuthenticationValid() async throws {
        func credentials(accessToken: String) -> ClaudeCodeProvider.ClaudeCodeCredentials {
            ClaudeCodeProvider.ClaudeCodeCredentials(
                loggedIn: true,
                authMethod: "oauth",
                apiProvider: "firstParty",
                userID: nil,
                claudeExecutablePath: nil,
                keychainCredentials: """
                {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"refresh-\(accessToken)","expiresAt":4102444800000}}
                """,
                authStatusJSON: nil,
                claudeSettingsJSON: nil,
                claudeJSON: #"{"oauthAccount":{"accountUuid":"cccccccc-cccc-4ccc-cccc-cccccccccccc"}}"#,
                claudeCredentialsJSON: nil,
                claudeAuthJSON: nil
            )
        }

        let provider = ClaudeCodeProvider()
        let original = credentials(accessToken: "old-token")
        let latest = credentials(accessToken: "new-token")
        let cacheKey = try #require(provider.usageCacheKey(original))
        defer { provider.clearUsageRateLimitMarker(cacheKey) }
        var attempts = 0

        let snapshot = try await provider.fetchOAuthUsageSnapshot(
            credentials: original,
            intent: .manual,
            requestUsage: { _ in
                attempts += 1
                if attempts == 1 {
                    throw OAuthUsageFetchError.unauthorized
                }
                throw OAuthUsageFetchError.rateLimited(retryAfter: nil)
            },
            readLatestCredentials: { latest }
        )

        #expect(snapshot == nil)
        #expect(attempts == 2)
        #expect(provider.isAuthRateLimited(original))
    }

    @Test("OAuth 401 never retries with another account's live token")
    func oauthUnauthorizedDoesNotCrossAccounts() async throws {
        func credentials(accountUuid: String, accessToken: String) -> ClaudeCodeProvider.ClaudeCodeCredentials {
            let tokenJSON = """
            {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"refresh-\(accessToken)","expiresAt":4102444800000}}
            """
            let accountJSON = """
            {"oauthAccount":{"accountUuid":"\(accountUuid)"}}
            """
            return ClaudeCodeProvider.ClaudeCodeCredentials(
                loggedIn: true,
                authMethod: "oauth",
                apiProvider: "firstParty",
                userID: nil,
                claudeExecutablePath: nil,
                keychainCredentials: tokenJSON,
                authStatusJSON: nil,
                claudeSettingsJSON: nil,
                claudeJSON: accountJSON,
                claudeCredentialsJSON: nil,
                claudeAuthJSON: nil
            )
        }

        let provider = ClaudeCodeProvider()
        let stored = credentials(
            accountUuid: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
            accessToken: "account-a-token"
        )
        let liveOtherAccount = credentials(
            accountUuid: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb",
            accessToken: "account-b-token"
        )
        var requestedTokens: [String] = []

        do {
            _ = try await provider.fetchOAuthUsageSnapshot(
                credentials: stored,
                // Bypass any rate-limit marker left by another parallel fixture; this test is
                // specifically about 401 account isolation.
                intent: .manual,
                requestUsage: { token in
                    requestedTokens.append(token)
                    if token == "account-a-token" {
                        throw OAuthUsageFetchError.unauthorized
                    }
                    return [:]
                },
                readLatestCredentials: {
                    liveOtherAccount
                }
            )
            Issue.record("401 should enter detached-account credential recovery")
        } catch let error as ProviderError {
            guard case .invalidCredentials = error else {
                Issue.record("unexpected provider error: \(error)")
                return
            }
        }
        #expect(requestedTokens == ["account-a-token"])
    }

    @Test("detached account can rotate a server-rejected token before local expiry")
    func detachedAuthenticationRecoveryForcesRefresh() async throws {
        let refreshToken = "fixture-\(UUID().uuidString)"
        let storedTokenJSON = """
        {"claudeAiOauth":{"accessToken":"stored-access","refreshToken":"\(refreshToken)","expiresAt":4102444800000}}
        """
        let liveOtherTokenJSON = """
        {"claudeAiOauth":{"accessToken":"other-access","refreshToken":"other-refresh","expiresAt":4102444800000}}
        """
        let stored = ClaudeCodeProvider.ClaudeCodeCredentials(
            loggedIn: true,
            authMethod: "oauth",
            apiProvider: "firstParty",
            userID: nil,
            claudeExecutablePath: nil,
            keychainCredentials: storedTokenJSON,
            authStatusJSON: nil,
            claudeSettingsJSON: nil,
            claudeJSON: nil,
            claudeCredentialsJSON: nil,
            claudeAuthJSON: nil
        )
        let provider = ClaudeCodeProvider()
        let now = Date()

        let notForced = await provider.refreshDetachedStoredCredentials(
            stored,
            liveKeychainCredentials: liveOtherTokenJSON,
            force: false,
            now: now,
            requestRefresh: { _, _ in
                Issue.record("locally valid token must not refresh without an authentication failure")
                return ClaudeCodeProvider.RefreshedOAuthToken(
                    accessToken: "unexpected",
                    refreshToken: "unexpected",
                    expiresAt: nil
                )
            }
        )
        #expect(notForced == nil)

        let refreshed = await provider.refreshDetachedStoredCredentials(
            stored,
            liveKeychainCredentials: liveOtherTokenJSON,
            force: true,
            now: now,
            requestRefresh: { receivedRefreshToken, _ in
                #expect(receivedRefreshToken == refreshToken)
                return ClaudeCodeProvider.RefreshedOAuthToken(
                    accessToken: "renewed-access",
                    refreshToken: "renewed-refresh",
                    expiresAt: now.addingTimeInterval(28_800)
                )
            }
        )
        let refreshedToken = try #require(refreshed.flatMap(provider.parseOAuthToken(from:)))
        #expect(refreshedToken.accessToken == "renewed-access")
        #expect(refreshedToken.refreshToken == "renewed-refresh")
        #expect(provider.isAuthenticationFailure(ProviderError.invalidCredentials))
        #expect(!provider.isAuthenticationFailure(ProviderError.network("offline")))
    }

    @Test("recent OAuth usage cache is explicitly labeled as cache")
    func recentOAuthUsageCacheIsLabeled() throws {
        let provider = ClaudeCodeProvider()
        let now = Date()
        let cachedAt = now.addingTimeInterval(-60)
        let cached = ClaudeCodeProvider.CachedClaudeUsage(
            schemaVersion: 1,
            cachedAt: cachedAt,
            snapshot: snapshot(
                primary: QuotaWindow(label: "5h", used: 40, limit: 100, resetAt: now.addingTimeInterval(3600)),
                updatedAt: cachedAt
            )
        )

        let preflight = provider.oauthUsagePreflight(
            cached: cached,
            rateLimitMarkerIsFresh: false,
            intent: .background,
            now: now
        )
        let reused = try #require(preflight.snapshot)
        #expect(!preflight.shouldRequestNetwork)
        #expect(reused.source == "Claude Code OAuth Cache")
        #expect(reused.updatedAt == cachedAt)
        #expect(reused.primary?.used == 40)
    }

    @Test("opening the panel fetches live usage the periodic cadence would have served from cache")
    func dashboardOpenShortensTheProviderCacheFloor() throws {
        let provider = ClaudeCodeProvider()
        let now = Date()

        func preflight(cacheAge: TimeInterval, intent: RefreshIntent) -> ClaudeCodeProvider.OAuthUsagePreflight {
            let cachedAt = now.addingTimeInterval(-cacheAge)
            return provider.oauthUsagePreflight(
                cached: ClaudeCodeProvider.CachedClaudeUsage(
                    schemaVersion: 1,
                    cachedAt: cachedAt,
                    snapshot: snapshot(
                        primary: QuotaWindow(label: "5h", used: 40, limit: 100, resetAt: now.addingTimeInterval(3600)),
                        updatedAt: cachedAt
                    )
                ),
                rateLimitMarkerIsFresh: false,
                intent: intent,
                now: now
            )
        }

        // 90s old: the background cadence still reuses its cache, the panel goes to the network.
        #expect(!preflight(cacheAge: 90, intent: .background).shouldRequestNetwork)
        #expect(!preflight(cacheAge: 90, intent: .visible).shouldRequestNetwork)
        #expect(preflight(cacheAge: 90, intent: .dashboardOpen).shouldRequestNetwork)

        // The panel floor is short, not absent — reopening seconds later must not re-hit `/usage`,
        // which 429s hard enough that hammering it leaves the panel showing older data.
        #expect(!preflight(cacheAge: 20, intent: .dashboardOpen).shouldRequestNetwork)

        // A throttled endpoint still wins over the panel; only an explicit manual refresh retries.
        let throttled = provider.oauthUsagePreflight(
            cached: nil,
            rateLimitMarkerIsFresh: true,
            intent: .dashboardOpen,
            now: now
        )
        #expect(!throttled.shouldRequestNetwork)
    }

    @Test("only a fresh usable statusLine skips OAuth usage")
    func freshUsableStatusLineSkipsOAuthUsage() {
        let provider = ClaudeCodeProvider()
        let capturedAt = Date()
        let usable = QuotaSnapshot(
            source: "Claude Code StatusLine",
            primary: QuotaWindow(label: "5h", used: 12, limit: 100, resetAt: capturedAt.addingTimeInterval(3600)),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: capturedAt,
            note: nil
        )
        let empty = QuotaSnapshot(
            source: "Claude Code StatusLine",
            primary: nil,
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: capturedAt,
            note: nil
        )

        #expect(provider.shouldPreferFreshStatusLine(
            usable,
            intent: .local,
            now: capturedAt.addingTimeInterval(60)
        ))
        for intent in [RefreshIntent.background, .visible, .manual] {
            #expect(!provider.shouldPreferFreshStatusLine(
                usable,
                intent: intent,
                now: capturedAt.addingTimeInterval(60)
            ))
        }
        #expect(!provider.shouldPreferFreshStatusLine(
            usable,
            intent: .local,
            now: capturedAt.addingTimeInterval(ClaudeCodeProvider.liveUsageMinFetchInterval + 1)
        ))
        #expect(!provider.shouldPreferFreshStatusLine(
            empty,
            intent: .local,
            now: capturedAt.addingTimeInterval(60)
        ))
    }

    @Test("day-old OAuth cache cannot fill a statusLine gap")
    func dayOldOAuthCacheCannotFillStatusLineGap() {
        let provider = ClaudeCodeProvider()
        let now = Date()
        let statusLine = QuotaSnapshot(
            source: "Claude Code StatusLine",
            primary: QuotaWindow(label: "5h", used: 12, limit: 100, resetAt: now.addingTimeInterval(3600)),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: now,
            note: nil
        )
        let cachedSnapshot = snapshot(
            primary: nil,
            secondary: QuotaWindow(label: "7d", used: 73, limit: 100, resetAt: nil),
            updatedAt: now.addingTimeInterval(-24 * 60 * 60)
        )

        let dayOld = ClaudeCodeProvider.CachedClaudeUsage(
            schemaVersion: 1,
            cachedAt: now.addingTimeInterval(-24 * 60 * 60),
            snapshot: cachedSnapshot
        )
        let unchanged = provider.fillStatusLineSnapshot(
            statusLine,
            fromHistoricalOAuthCache: dayOld,
            now: now
        )
        #expect(unchanged.source == "Claude Code StatusLine")
        #expect(unchanged.primary?.used == 12)
        #expect(unchanged.secondary == nil)

        let recent = ClaudeCodeProvider.CachedClaudeUsage(
            schemaVersion: 1,
            cachedAt: now.addingTimeInterval(-29 * 60),
            snapshot: cachedSnapshot
        )
        let filled = provider.fillStatusLineSnapshot(
            statusLine,
            fromHistoricalOAuthCache: recent,
            now: now
        )
        #expect(filled.source == "Claude Code StatusLine")
        #expect(filled.secondary?.used == 73)
    }

    @Test("stale-data age humanizes to minutes, hours, and days")
    func humanizedAgeFormatting() {
        #expect(AppText.humanizedAge(minutes: 12, language: .simplifiedChinese) == "12 分钟")
        #expect(AppText.humanizedAge(minutes: 480, language: .simplifiedChinese) == "8 小时")
        #expect(AppText.humanizedAge(minutes: 480, language: .traditionalChinese) == "8 小時")
        #expect(AppText.humanizedAge(minutes: 3000, language: .simplifiedChinese) == "2 天")
        #expect(AppText.humanizedAge(minutes: 90, language: .english) == "1 hour")
        #expect(AppText.humanizedAge(minutes: 2880, language: .english) == "2 days")
    }

    @Test("compact error summary keeps only the actionable first sentence")
    func compactErrorSummaryFirstSentence() {
        let zh = AppText(language: .simplifiedChinese)
        #expect(zh.compactErrorSummary("Claude Code 需要重新登录。请重新登录 Claude Code，然后刷新 QuotaBar。") == "Claude Code 需要重新登录")
        #expect(zh.compactErrorSummary("本地登录记录需要重新建立。请在 QuotaBar 删除该账号后重新添加。") == "本地登录记录需要重新建立")

        let en = AppText(language: .english)
        #expect(en.compactErrorSummary("Claude Code needs a fresh sign-in. Sign in to Claude Code again, then refresh QuotaBar.") == "Claude Code needs a fresh sign-in")

        // No sentence break: returned unchanged.
        #expect(zh.compactErrorSummary("刷新中") == "刷新中")
    }

    @Test("expired credentials serve cached data with recovery guidance, never a re-login nag")
    func expiredCredentialFallbackGuidance() throws {
        let provider = ClaudeCodeProvider()
        let now = Date()
        let cached = ClaudeCodeProvider.CachedClaudeUsage(
            schemaVersion: 1,
            cachedAt: now.addingTimeInterval(-3600),
            snapshot: snapshot(
                primary: QuotaWindow(label: "5h", used: 40, limit: 100, resetAt: now.addingTimeInterval(3600)),
                updatedAt: now.addingTimeInterval(-3600)
            )
        )

        let fallback = try #require(provider.expiredCredentialFallback(cached))
        #expect(fallback.note == QuotaNoteCatalog.claudeCredentialsAwaitingClaudeCode)
        #expect(fallback.source == "Claude Code OAuth Cache")
        #expect(fallback.primary?.label == "5h")

        // Nothing usable left in the cache: no snapshot at all rather than misleading zeros.
        let allExpired = ClaudeCodeProvider.CachedClaudeUsage(
            schemaVersion: 1,
            cachedAt: now.addingTimeInterval(-3600),
            snapshot: snapshot(
                primary: QuotaWindow(label: "5h", used: 100, limit: 100, resetAt: now.addingTimeInterval(-90 * 60)),
                updatedAt: now.addingTimeInterval(-3600)
            )
        )
        #expect(provider.expiredCredentialFallback(allExpired) == nil)
        #expect(provider.expiredCredentialFallback(nil) == nil)
    }

    @Test("hard expiry follows the stored expiresAt")
    func tokenHardExpiry() {
        func token(expiresIn: TimeInterval?) -> ClaudeCodeProvider.ClaudeOAuthToken {
            ClaudeCodeProvider.ClaudeOAuthToken(
                accessToken: "token",
                refreshToken: nil,
                expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
            )
        }

        #expect(!token(expiresIn: 600).isHardExpired)
        #expect(token(expiresIn: -1).isHardExpired)
        // Missing expiry metadata: assume usable and let the server be the judge.
        #expect(!token(expiresIn: nil).isHardExpired)
    }

    @Test("credential guidance note localizes and shows on the card")
    func credentialGuidanceNoteLocalization() {
        let note = QuotaNoteCatalog.claudeCredentialsAwaitingClaudeCode
        let en = AppText(language: .english)
        #expect(en.localizedNote(note)?.contains("live data resumes") == true)
        #expect(en.shouldDisplayNoteOnCard(note))
        let zh = AppText(language: .simplifiedChinese)
        #expect(zh.localizedNote(note) == note)
    }

    @Test("dead grants are recognized from the OAuth error body")
    func permanentRefreshFailureDetection() {
        func body(_ text: String) -> Data { Data(text.utf8) }

        #expect(ClaudeCodeProvider.isPermanentTokenRefreshFailure(body: body(#"{"error":"invalid_grant"}"#)))
        #expect(ClaudeCodeProvider.isPermanentTokenRefreshFailure(body: body("Invalid refresh token")))
        #expect(!ClaudeCodeProvider.isPermanentTokenRefreshFailure(body: body(#"{"error":"invalid_request"}"#)))
        #expect(!ClaudeCodeProvider.isPermanentTokenRefreshFailure(body: body(#"{"error":"temporarily_unavailable"}"#)))
        #expect(!ClaudeCodeProvider.isPermanentTokenRefreshFailure(body: Data()))
    }

}
