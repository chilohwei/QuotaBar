import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Provider payload fixtures")
struct ProviderPayloadFixtureTests {
    @Test("Codex backend usage payload maps percent windows, credits, plan and subscription")
    func codexBackendUsagePayload() throws {
        let payload = try jsonObject("""
        {
          "rate_limit": {
            "allowed": true,
            "primary_window": {
              "used_percent": 0.42,
              "limit_window_seconds": 18000,
              "reset_at": "2026-06-05T12:30:00Z"
            },
            "secondaryWindow": {
              "usedPercent": 83,
              "limitWindowSeconds": 604800,
              "resetAt": 1780000000000
            }
          },
          "credits": {
            "remaining": "12.50",
            "used": "7.50"
          },
          "chatgpt_plan_type": "plus",
          "billing_period": "monthly"
        }
        """)

        let validUntil = Date(timeIntervalSince1970: 1_780_100_000)
        let snapshot = try #require(CodexProvider().parseRateLimitPayloadForTesting(
            payload,
            accountIdentifier: "codex@example.com",
            accountValidUntil: validUntil,
            subscriptionWillRenew: true,
            subscriptionStatus: "active"
        ))

        #expect(snapshot.accountIdentifier == "codex@example.com")
        #expect(snapshot.planName == "Plus Monthly")
        #expect(snapshot.primary?.label == "5h")
        #expect(snapshot.primary?.used == 42)
        #expect(snapshot.secondary?.label == "Weekly")
        #expect(snapshot.secondary?.used == 83)
        #expect(snapshot.creditsRemaining == 12.5)
        #expect(snapshot.creditsTotal == 20)
        #expect(snapshot.accountValidUntil == validUntil)
        #expect(snapshot.subscriptionWillRenew == true)
        #expect(snapshot.subscriptionStatus == "active")
        #expect(snapshot.isQuotaBlocked == false)
    }

    @Test("Codex backend blocked payload does not masquerade as usable")
    func codexBackendBlockedPayload() throws {
        let payload = try jsonObject("""
        {
          "rateLimit": {
            "allowed": false,
            "limitReached": true,
            "primaryWindow": {
              "usedPercent": 100,
              "windowMinutes": 300
            }
          },
          "planName": "free"
        }
        """)

        let snapshot = try #require(CodexProvider().parseRateLimitPayloadForTesting(payload))

        #expect(snapshot.planName == "Free")
        #expect(snapshot.primary?.remainingPercent == 0)
        #expect(snapshot.isQuotaBlocked == true)
    }

    @Test("Cursor current usage payload maps plan capacity and percent windows")
    func cursorCurrentUsagePayload() throws {
        let payload = try jsonObject("""
        {
          "membershipType": "pro_plus",
          "current_period_end": "2026-06-30T00:00:00Z",
          "subscriptionStatus": "active",
          "planUsage": {
            "used": 2500,
            "limit": 10000
          },
          "autoPercentUsed": 0.6,
          "apiPercentUsed": 82,
          "onDemand": {
            "enabled": true,
            "used": 1200,
            "limit": 5000
          }
        }
        """)

        let snapshot = try CursorProvider().parseCurrentPeriodUsageForTesting(
            payload,
            email: "cursor@example.com"
        )

        #expect(snapshot.accountIdentifier == "cursor@example.com")
        #expect(snapshot.planName == "Pro+")
        #expect(snapshot.primary?.label == "Total")
        #expect(snapshot.primary?.used == 2500)
        #expect(snapshot.primary?.limit == 10000)
        #expect(snapshot.secondary?.label == "Auto")
        #expect(snapshot.secondary?.used == 60)
        #expect(snapshot.tertiary?.label == "API")
        #expect(snapshot.tertiary?.used == 82)
        #expect(snapshot.subscriptionWillRenew == true)
        #expect(snapshot.subscriptionStatus == "active")
        #expect(snapshot.note?.contains("Included") == true)
    }

    @Test("Cursor callback-shaped usage payload maps labeled rows")
    func cursorCallbackUsageRowsPayload() throws {
        let payload = try jsonObject("""
        {
          "membership_type": "pro",
          "billingCycleEnd": 1782864000000,
          "usageRows": [
            {
              "name": "included",
              "usedCents": "3750",
              "limitCents": "10000"
            },
            {
              "bucket": "api",
              "percentUsed": "82%"
            },
            {
              "type": "usage_based_premium_requests",
              "usageCents": 1200,
              "hardLimitCents": 5000
            }
          ]
        }
        """)

        let snapshot = try CursorProvider().parseCurrentPeriodUsageForTesting(
            payload,
            email: "cursor-callback@example.com"
        )

        #expect(snapshot.accountIdentifier == "cursor-callback@example.com")
        #expect(snapshot.planName == "Pro")
        #expect(snapshot.primary?.label == "Included")
        #expect(snapshot.primary?.used == 3750)
        #expect(snapshot.primary?.limit == 10000)
        #expect(snapshot.secondary?.label == "API")
        #expect(snapshot.secondary?.used == 82)
        #expect(snapshot.secondary?.limit == 100)
        #expect(snapshot.tertiary?.label == "On-demand")
        #expect(snapshot.tertiary?.used == 1200)
        #expect(snapshot.tertiary?.limit == 5000)
    }

    @Test("Cursor zero placeholder payload produces no fake 100 percent remaining quota")
    func cursorZeroPlaceholderPayload() throws {
        let payload = try jsonObject("""
        {
          "membershipType": "free",
          "totalPercentUsed": 0,
          "autoPercentUsed": 0,
          "apiPercentUsed": 0,
          "planUsage": {
            "used": 0,
            "limit": 0,
            "remaining": 0
          }
        }
        """)

        let snapshot = try CursorProvider().parseCurrentPeriodUsageForTesting(payload)

        #expect(snapshot.planName == "Free")
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
    }

    @Test("Claude statusLine payload maps 5h 7d without context or subscription panel")
    func claudeStatusLinePayload() throws {
        let status = try jsonDictionary("""
        {
          "model": {
            "display_name": "Claude Sonnet 4"
          },
          "rate_limits": {
            "five_hour": {
              "used_percentage": 64,
              "resets_at": "2026-06-05T14:00:00Z"
            },
            "seven_day": {
              "used_percentage": "91",
              "reset_at": 1780200000000
            }
          },
          "context_window": {
            "context_window_size": 200000,
            "current_usage": {
              "input_tokens": 80000,
              "cache_creation_input_tokens": 10000,
              "cache_read_input_tokens": 10000
            }
          }
        }
        """)

        let snapshot = ClaudeCodeProvider().parseStatusLineSnapshotForTesting(
            status,
            authMethod: "oauth",
            apiProvider: "firstParty",
            userID: "user-12345678",
            authStatusJSON: #"{"email":"claude-user@example.com"}"#
        )

        #expect(snapshot.source == "Claude Code StatusLine")
        #expect(snapshot.accountIdentifier == "claude-user@example.com")
        #expect(snapshot.planName == "Claude.ai")
        #expect(snapshot.primary?.label == "5h")
        #expect(snapshot.primary?.used == 64)
        #expect(snapshot.secondary?.label == "7d")
        #expect(snapshot.secondary?.used == 91)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.accountValidUntil == nil)
        #expect(snapshot.subscriptionStatus == nil)
        #expect(snapshot.subscriptionWillRenew == nil)
        #expect(snapshot.isQuotaBlocked == false)
    }

    @Test("Claude OAuth token expiry is not shown as account expiration")
    func claudeOAuthTokenExpiryIsNotAccountExpiration() throws {
        let status = try jsonDictionary("""
        {
          "rate_limits": {
            "five_hour": {
              "used_percentage": 1,
              "resets_at": 1782540000
            }
          }
        }
        """)

        let snapshot = ClaudeCodeProvider().parseStatusLineSnapshotForTesting(
            status,
            keychainCredentials: #"{"claudeAiOauth":{"expiresAt":1782553821650}}"#
        )

        #expect(snapshot.accountValidUntil == nil)
    }

    @Test("Claude statusLine payload with quota windows is usable without install metadata")
    func claudeStatusLinePayloadIsUsableWithoutInstallMetadata() throws {
        let status = try jsonDictionary("""
        {
          "rate_limits": {
            "five_hour": {
              "used_percentage": 1,
              "resets_at": 1782540000
            },
            "seven_day": {
              "used_percentage": 18,
              "resets_at": 1782637200
            }
          }
        }
        """)

        #expect(ClaudeCodeProvider().shouldUseStatusLineSnapshotForTesting(status) == true)
    }

    @Test("Claude third party payload keeps provider identity without context panel")
    func claudeThirdPartyPayload() throws {
        let status = try jsonDictionary("""
        {
          "model": {
            "display_name": "mimo-v1"
          },
          "context_window": {
            "used_percentage": 73
          }
        }
        """)

        let snapshot = ClaudeCodeProvider().parseStatusLineSnapshotForTesting(
            status,
            authMethod: "api_key",
            apiProvider: "https://api.xiaomimimo.com"
        )

        #expect(snapshot.planName == "Xiaomi Mimo")
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.note?.contains("API Key") == true)
    }

    private func jsonObject(_ text: String) throws -> Any {
        let data = try #require(text.data(using: .utf8))
        return try JSONSerialization.jsonObject(with: data)
    }

    private func jsonDictionary(_ text: String) throws -> [String: Any] {
        try #require(jsonObject(text) as? [String: Any])
    }
}
