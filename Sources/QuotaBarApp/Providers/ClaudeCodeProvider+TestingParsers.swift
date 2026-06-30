import Foundation

extension ClaudeCodeProvider {
#if DEBUG
    func parseStatusLineSnapshotForTesting(
        _ status: [String: Any],
        authMethod: String? = "oauth",
        apiProvider: String? = "firstParty",
        userID: String? = "fixture-user",
        authStatusJSON: String? = nil,
        claudeSettingsJSON: String? = nil,
        keychainCredentials: String? = nil,
        capturedAt: Date = Date(),
        now: Date = Date(),
        rateLimitTranscriptLine: String? = nil
    ) -> QuotaSnapshot {
        let credentials = ClaudeCodeCredentials(
            loggedIn: true,
            authMethod: authMethod,
            apiProvider: apiProvider,
            userID: userID,
            claudeExecutablePath: nil,
            keychainCredentials: keychainCredentials,
            authStatusJSON: authStatusJSON,
            claudeSettingsJSON: claudeSettingsJSON,
            claudeJSON: nil,
            claudeCredentialsJSON: nil,
            claudeAuthJSON: nil
        )
        let rateLimitEvent = rateLimitTranscriptLine.flatMap {
            parseRateLimitEvent(jsonLine: $0, fileModifiedAt: nil, now: now)
        }
        return makeQuotaSnapshot(
            status: status,
            credentials: credentials,
            capturedAt: capturedAt,
            now: now,
            rateLimitEvent: rateLimitEvent
        )
    }

    func parseOAuthUsagePayloadForTesting(
        _ payload: [String: Any],
        authMethod: String? = "oauth",
        apiProvider: String? = "firstParty",
        userID: String? = "fixture-user",
        authStatusJSON: String? = nil,
        now: Date = Date(),
        rateLimitTranscriptLine: String? = nil
    ) -> QuotaSnapshot {
        let credentials = ClaudeCodeCredentials(
            loggedIn: true,
            authMethod: authMethod,
            apiProvider: apiProvider,
            userID: userID,
            claudeExecutablePath: nil,
            keychainCredentials: nil,
            authStatusJSON: authStatusJSON,
            claudeSettingsJSON: nil,
            claudeJSON: nil,
            claudeCredentialsJSON: nil,
            claudeAuthJSON: nil
        )
        let snapshot = makeOAuthUsageSnapshot(payload: payload, credentials: credentials)
        let rateLimitEvent = rateLimitTranscriptLine.flatMap {
            parseRateLimitEvent(jsonLine: $0, fileModifiedAt: nil, now: now)
        }
        return applyActiveRateLimit(to: snapshot, rateLimitEvent: rateLimitEvent, now: now)
    }

    func shouldUseStatusLineSnapshotForTesting(_ status: [String: Any], settingsJSON: String? = nil) -> Bool {
        shouldUseStatusLineSnapshot(status, settingsJSON: settingsJSON)
    }
#endif
}
