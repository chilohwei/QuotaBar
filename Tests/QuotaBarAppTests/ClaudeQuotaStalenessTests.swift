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
            note: nil
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

    @Test("self-refresh waits out the grace window so an active CLI keeps first claim")
    func selfRefreshGraceWindow() {
        let now = Date()
        let grace = ClaudeCodeProvider.selfRefreshGrace

        func gate(expiredFor: TimeInterval?, blockedUntil: Date? = nil, intent: RefreshIntent = .background) -> Bool {
            ClaudeCodeProvider.shouldAttemptSelfRefresh(
                expiresAt: expiredFor.map { now.addingTimeInterval(-$0) },
                blockedUntil: blockedUntil,
                intent: intent,
                now: now
            )
        }

        // Still valid, freshly expired, or unknown expiry: the CLI may be mid-rotation — hands off.
        #expect(!gate(expiredFor: -600))
        #expect(!gate(expiredFor: 60))
        #expect(!gate(expiredFor: grace - 1))
        #expect(!gate(expiredFor: nil))

        // Sat expired past the grace: no other maintainer exists, take over.
        #expect(gate(expiredFor: grace))
        #expect(gate(expiredFor: 6 * 3600))
    }

    @Test("self-refresh backoff blocks background retries but yields to manual refresh, never the grace")
    func selfRefreshBackoff() {
        let now = Date()
        let expiredLongAgo: TimeInterval = 2 * ClaudeCodeProvider.selfRefreshGrace
        let blocked = now.addingTimeInterval(600)

        func gate(expiredFor: TimeInterval, blockedUntil: Date?, intent: RefreshIntent) -> Bool {
            ClaudeCodeProvider.shouldAttemptSelfRefresh(
                expiresAt: now.addingTimeInterval(-expiredFor),
                blockedUntil: blockedUntil,
                intent: intent,
                now: now
            )
        }

        #expect(!gate(expiredFor: expiredLongAgo, blockedUntil: blocked, intent: .background))
        #expect(!gate(expiredFor: expiredLongAgo, blockedUntil: blocked, intent: .visible))
        #expect(gate(expiredFor: expiredLongAgo, blockedUntil: blocked, intent: .manual))
        // An elapsed block no longer gates.
        #expect(gate(expiredFor: expiredLongAgo, blockedUntil: now.addingTimeInterval(-1), intent: .background))
        // Manual bypasses the backoff but not the grace.
        #expect(!gate(expiredFor: 60, blockedUntil: nil, intent: .manual))
    }

    @Test("dead grants are recognized from the OAuth error body")
    func permanentRefreshFailureDetection() {
        func body(_ text: String) -> Data { Data(text.utf8) }

        #expect(ClaudeCodeProvider.isPermanentTokenRefreshFailure(body: body(#"{"error":"invalid_grant"}"#)))
        #expect(ClaudeCodeProvider.isPermanentTokenRefreshFailure(body: body("Invalid refresh token")))
        #expect(!ClaudeCodeProvider.isPermanentTokenRefreshFailure(body: body(#"{"error":"temporarily_unavailable"}"#)))
        #expect(!ClaudeCodeProvider.isPermanentTokenRefreshFailure(body: Data()))
    }

}
