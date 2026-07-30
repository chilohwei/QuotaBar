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

    @Test("Codex paid plan payload maps team and pro names without dropping quota")
    func codexPaidPlanPayloads() throws {
        let teamPayload = try jsonObject("""
        {
          "rate_limit": {
            "allowed": true,
            "primary_window": {
              "used_percent": 12,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 45,
              "limit_window_seconds": 604800
            }
          },
          "chatgpt_plan_type": "team",
          "billing_cycle": "annual"
        }
        """)
        let teamSnapshot = try #require(CodexProvider().parseRateLimitPayloadForTesting(
            teamPayload,
            accountValidUntil: Date(timeIntervalSince1970: 1_800_000_000),
            subscriptionWillRenew: true,
            subscriptionStatus: "active"
        ))

        #expect(teamSnapshot.planName == "Team Annual")
        #expect(teamSnapshot.primary?.remainingPercent == 88)
        #expect(approximately(teamSnapshot.secondary?.remainingPercent, 55))
        #expect(teamSnapshot.accountValidUntil != nil)
        #expect(teamSnapshot.subscriptionWillRenew == true)

        let proPayload = try jsonObject("""
        {
          "rateLimit": {
            "allowed": true,
            "primaryWindow": {
              "usedPercent": 0.35,
              "windowMinutes": 300
            }
          },
          "planName": "chatgpt pro"
        }
        """)
        let proSnapshot = try #require(CodexProvider().parseRateLimitPayloadForTesting(proPayload))

        #expect(proSnapshot.planName == "Pro")
        #expect(proSnapshot.primary?.remainingPercent == 65)
        #expect(proSnapshot.isQuotaBlocked == false)
    }

    @Test("Cursor current usage payload maps plan capacity and percent windows")
    func cursorCurrentUsagePayload() throws {
        let payload = try jsonObject("""
        {
          "membershipType": "pro_plus",
          "current_period_end": "2026-06-30T00:00:00Z",
          "subscriptionStatus": "active",
          "planUsage": {
            "includedSpend": 2500,
            "limit": 10000,
            "totalPercentUsed": 25,
            "autoPercentUsed": 60,
            "apiPercentUsed": 82
          },
          "spendLimitUsage": {
            "enabled": true,
            "individualUsed": 1200,
            "individualLimit": 5000
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
        #expect(snapshot.primary?.used == 25)
        #expect(snapshot.primary?.limit == 100)
        #expect(snapshot.secondary?.label == "Auto")
        #expect(snapshot.secondary?.used == 60)
        #expect(snapshot.tertiary?.label == "API")
        #expect(snapshot.tertiary?.used == 82)
        #expect(snapshot.subscriptionWillRenew == true)
        #expect(snapshot.subscriptionStatus == "active")
        #expect(snapshot.note?.contains("Included") == true)
    }

    @Test("Cursor team payload maps business plan and quota buckets")
    func cursorTeamUsagePayload() throws {
        let payload = try jsonObject("""
        {
          "membership_type": "business",
          "subscription_status": "active",
          "current_period_end": "2026-07-31T00:00:00Z",
          "planUsage": {
            "totalSpend": 4200,
            "limit": 12000,
            "autoPercentUsed": 44,
            "apiPercentUsed": 8
          },
          "spend_limit_usage": {
            "enabled": true,
            "individualUsed": 500,
            "individualLimit": 5000
          }
        }
        """)

        let snapshot = try CursorProvider().parseCurrentPeriodUsageForTesting(
            payload,
            email: "cursor-team@example.com"
        )

        #expect(snapshot.accountIdentifier == "cursor-team@example.com")
        #expect(snapshot.planName == "Team")
        #expect(snapshot.primary?.label == "Total")
        #expect(approximately(snapshot.primary?.remainingPercent, 65))
        #expect(snapshot.secondary?.label == "Auto")
        #expect(approximately(snapshot.secondary?.remainingPercent, 56))
        #expect(snapshot.tertiary?.label == "API")
        #expect(snapshot.tertiary?.remainingPercent == 92)
        #expect(snapshot.subscriptionWillRenew == true)
    }

    @Test("Cursor usage payload email names account when token has no email")
    func cursorUsagePayloadEmailNamesAccount() throws {
        let payload = try jsonObject("""
        {
          "user": {
            "userEmail": "CURSOR-API@example.com"
          },
          "membershipType": "pro",
          "planUsage": {
            "used": 1200,
            "limit": 10000
          }
        }
        """)

        let snapshot = try CursorProvider().parseCurrentPeriodUsageForTesting(
            payload,
            email: nil
        )

        #expect(snapshot.accountIdentifier == "cursor-api@example.com")
        #expect(snapshot.planName == "Pro")
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

    @Test("Cursor free included-usage payload renders full remaining instead of hiding quota")
    func cursorFreeIncludedUsagePayload() throws {
        // Real shape returned by GetCurrentPeriodUsage for an unused Free account:
        // the included allowance is reported only as percentages (all 0 == 100%
        // remaining), accompanied by a positive display threshold and an
        // "included usage" message. This must not collapse to "no quota".
        let payload = try jsonObject("""
        {
          "billingCycleStart": "1780998365124",
          "billingCycleEnd": "1783590365124",
          "planUsage": {
            "remainingBonus": false,
            "autoPercentUsed": 0,
            "apiPercentUsed": 0,
            "totalPercentUsed": 0
          },
          "spendLimitUsage": {
            "pooledLimit": 0,
            "pooledRemaining": 0,
            "individualLimit": 0,
            "overallLimit": 0,
            "overallRemaining": 0
          },
          "displayThreshold": 200,
          "displayMessage": "You've used 0% of your included usage",
          "autoBucketModels": ["composer-2.5", "composer-2"]
        }
        """)

        let snapshot = try CursorProvider().parseCurrentPeriodUsageForTesting(
            payload,
            email: "cursor-free@example.com",
            membershipType: "free"
        )

        #expect(snapshot.planName == "Free")
        #expect(snapshot.primary?.label == "Total")
        #expect(snapshot.primary?.used == 0)
        #expect(snapshot.primary?.limit == 100)
        #expect(snapshot.primary?.remainingPercent == 100)
        #expect(snapshot.isQuotaBlocked != true)
        // A Free account has a single included allowance — it should not mirror the
        // paid Auto / API three-bucket layout.
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
    }

    @Test("Cursor free login without stored plan name still renders single Total bar")
    func cursorFreeMissingPlanNameIncludedUsagePayload() throws {
        // Real GetCurrentPeriodUsage response for a Free account whose local Cursor
        // state omits `stripeMembershipType` (so membershipType is nil). The bonus
        // allowance is reported via `totalSpend`/`bonusSpend` with no dollar limit —
        // this must not be read as paid capacity and expose Auto / API buckets.
        let payload = try jsonObject("""
        {
          "billingCycleStart": "1782119059049",
          "billingCycleEnd": "1784711059049",
          "planUsage": {
            "totalSpend": 172,
            "bonusSpend": 172,
            "remainingBonus": false,
            "autoPercentUsed": 0,
            "apiPercentUsed": 100,
            "totalPercentUsed": 86
          },
          "spendLimitUsage": {
            "pooledLimit": 0,
            "pooledRemaining": 0,
            "individualLimit": 0,
            "limitType": "user",
            "overallLimit": 0,
            "overallRemaining": 0
          },
          "displayThreshold": 200,
          "displayMessage": "You've used 0% of your included usage",
          "autoModelSelectedDisplayMessage": "You've used 86% of your included total usage",
          "namedModelSelectedDisplayMessage": "You've used 100% of your included API usage",
          "autoBucketModels": ["default"]
        }
        """)

        let snapshot = try CursorProvider().parseCurrentPeriodUsageForTesting(
            payload,
            email: "cursor-free@example.com",
            membershipType: nil
        )

        #expect(snapshot.primary?.label == "Total")
        #expect(snapshot.primary?.used == 86)
        #expect(snapshot.primary?.limit == 100)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
    }

    @Test("Cursor free partially-used included usage does not expose paid Auto API buckets")
    func cursorFreePartiallyUsedIncludedUsagePayload() throws {
        let payload = try jsonObject("""
        {
          "billingCycleStart": "1780998365124",
          "billingCycleEnd": "1783590365124",
          "planUsage": {
            "remainingBonus": false,
            "autoPercentUsed": 100,
            "apiPercentUsed": 0,
            "totalPercentUsed": 98
          },
          "spendLimitUsage": {
            "pooledLimit": 0,
            "pooledRemaining": 0,
            "individualLimit": 0,
            "overallLimit": 0,
            "overallRemaining": 0
          },
          "displayThreshold": 200,
          "displayMessage": "You've used 98% of your included usage",
          "autoBucketModels": ["composer-2.5", "composer-2"]
        }
        """)

        let snapshot = try CursorProvider().parseCurrentPeriodUsageForTesting(
            payload,
            email: "cursor-free@example.com",
            membershipType: "free"
        )

        #expect(snapshot.planName == "Free")
        #expect(snapshot.primary?.label == "Total")
        #expect(snapshot.primary?.used == 98)
        #expect(snapshot.primary?.limit == 100)
        #expect(approximately(snapshot.primary?.remainingPercent, 2))
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.statusBarMetric?.title == "Total")
        #expect(approximately(snapshot.statusBarMetric?.ratio, 0.02))
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
            authStatusJSON: #"{"email":"claude-user@example.com"}"#,
            capturedAt: Date(timeIntervalSince1970: 1_770_000_000),
            now: Date(timeIntervalSince1970: 1_770_000_000)
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

    @Test("Claude statusLine payload accepts weekly aliases")
    func claudeStatusLinePayloadAcceptsWeeklyAliases() throws {
        let status = try jsonDictionary("""
        {
          "rate_limits": {
            "fiveHour": {
              "used_percentage": 64,
              "resetsAt": "2026-06-05T14:00:00Z"
            },
            "weekly_all_models": {
              "used_percentage": 15,
              "nextResetAt": 1780200000000
            }
          }
        }
        """)

        let snapshot = ClaudeCodeProvider().parseStatusLineSnapshotForTesting(
            status,
            capturedAt: Date(timeIntervalSince1970: 1_770_000_000),
            now: Date(timeIntervalSince1970: 1_770_000_000)
        )

        #expect(snapshot.primary?.label == "5h")
        #expect(snapshot.primary?.used == 64)
        #expect(snapshot.primary?.resetAt == ISO8601DateFormatter().date(from: "2026-06-05T14:00:00Z"))
        #expect(snapshot.secondary?.label == "7d")
        #expect(snapshot.secondary?.used == 15)
        #expect(snapshot.orderedMetrics.count == 2)
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

    @Test("Claude local rate-limit transcript marks block without rewriting statusLine quota")
    func claudeRateLimitTranscriptMarksBlockWithoutRewritingStatusLine() throws {
        let status = try jsonDictionary("""
        {
          "rate_limits": {
            "five_hour": {
              "used_percentage": 71,
              "resets_at": 1782733800
            },
            "seven_day": {
              "used_percentage": 12,
              "resets_at": 1783242000
            }
          }
        }
        """)
        let rateLimitLine = """
        {"type":"assistant","timestamp":"2026-06-29T10:40:27.000Z","message":{"content":[{"type":"text","text":"Usage limit reached · resets at 7:50 PM (Asia/Shanghai)"}]},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}
        """

        let snapshot = ClaudeCodeProvider().parseStatusLineSnapshotForTesting(
            status,
            capturedAt: Date(timeIntervalSince1970: 1_782_730_800),
            now: Date(timeIntervalSince1970: 1_782_730_800),
            rateLimitTranscriptLine: rateLimitLine
        )

        #expect(snapshot.primary?.used == 71)
        #expect(snapshot.primary?.resetAt == Date(timeIntervalSince1970: 1_782_733_800))
        #expect(snapshot.secondary?.used == 12)
        #expect(snapshot.isQuotaBlocked == true)
        #expect(snapshot.effectiveAvailabilityStatus == .sessionRateLimited)
        #expect(approximately(snapshot.statusBarMetric?.ratio, 0.29))
        #expect(snapshot.note == QuotaNoteCatalog.claudeRateLimitReached)
    }

    @Test("Claude expired local rate-limit transcript does not override current statusLine")
    func claudeExpiredRateLimitTranscriptDoesNotOverrideStatusLine() throws {
        let status = try jsonDictionary("""
        {
          "rate_limits": {
            "five_hour": {
              "used_percentage": 71,
              "resets_at": 1782733800
            }
          }
        }
        """)
        let rateLimitLine = """
        {"type":"assistant","timestamp":"2026-06-29T04:00:00.000Z","message":{"content":[{"type":"text","text":"You've hit your session limit · resets 3pm (Asia/Shanghai)"}]},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}
        """

        let snapshot = ClaudeCodeProvider().parseStatusLineSnapshotForTesting(
            status,
            capturedAt: Date(timeIntervalSince1970: 1_782_730_800),
            now: Date(timeIntervalSince1970: 1_782_730_800),
            rateLimitTranscriptLine: rateLimitLine
        )

        #expect(snapshot.primary?.used == 71)
        #expect(snapshot.isQuotaBlocked == false)
    }

    @Test("Claude transcript that only mentions a limit in text does not force a block")
    func claudeRateLimitTextWithoutApiErrorMarkersIsIgnored() throws {
        let status = try jsonDictionary("""
        {
          "rate_limits": {
            "five_hour": {
              "used_percentage": 40,
              "resets_at": 1782744600
            }
          }
        }
        """)
        // A non-error transcript line (tool output / assistant discussion / this very session)
        // that contains the words but lacks the top-level apiErrorStatus / error / isApiErrorMessage
        // markers of a real 429. It must NOT be treated as an active rate limit.
        let discussionLine = """
        {"type":"assistant","timestamp":"2026-06-29T13:39:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"You've hit your session limit · resets 7:50pm (Asia/Shanghai) — investigating why the panel shows this."}]}}
        """

        let snapshot = ClaudeCodeProvider().parseStatusLineSnapshotForTesting(
            status,
            capturedAt: Date(timeIntervalSince1970: 1_782_740_000),
            now: Date(timeIntervalSince1970: 1_782_740_000),
            rateLimitTranscriptLine: discussionLine
        )

        #expect(snapshot.primary?.used == 40)
        #expect(snapshot.isQuotaBlocked == false)
        #expect(snapshot.note?.contains("Usage limit reached") != true)
    }

    @Test("Claude OAuth usage payload maps utilization windows and blocked state")
    func claudeOAuthUsagePayload() throws {
        let payload = try jsonDictionary("""
        {
          "five_hour": {
            "utilization": 100,
            "resets_at": "2026-06-28T07:00:00Z"
          },
          "seven_day": {
            "utilization": 31,
            "resets_at": "2026-06-28T09:00:00Z"
          }
        }
        """)

        let snapshot = ClaudeCodeProvider().parseOAuthUsagePayloadForTesting(
            payload,
            authStatusJSON: #"{"email":"claude-user@example.com"}"#
        )

        #expect(snapshot.source == "Claude Code OAuth")
        #expect(snapshot.accountIdentifier == "claude-user@example.com")
        #expect(snapshot.primary?.used == 100)
        #expect(snapshot.secondary?.used == 31)
        #expect(snapshot.isQuotaBlocked == true)
        #expect(snapshot.effectiveAvailabilityStatus == .quotaExhausted)
    }

    @Test("Claude OAuth usage payload accepts weekly aliases")
    func claudeOAuthUsagePayloadAcceptsWeeklyAliases() throws {
        let payload = try jsonDictionary("""
        {
          "rateLimits": {
            "fiveHour": {
              "utilization": 100,
              "resetsAt": "2026-06-28T07:00:00Z"
            },
            "weekly_all_models": {
              "utilization": 15,
              "nextResetAt": "2026-07-05T12:00:00Z"
            }
          }
        }
        """)

        let snapshot = ClaudeCodeProvider().parseOAuthUsagePayloadForTesting(
            payload,
            authStatusJSON: #"{"email":"claude-user@example.com"}"#
        )

        #expect(snapshot.primary?.used == 100)
        #expect(snapshot.secondary?.label == "7d")
        #expect(snapshot.secondary?.used == 15)
        #expect(snapshot.orderedMetrics.count == 2)
    }

    @Test("Claude OAuth usage payload reads weekly windows from the limits array")
    func claudeOAuthUsagePayloadReadsLimitsArray() throws {
        // Newer /usage payloads null out `seven_day` and describe the weekly windows in a
        // `limits` array, model-scoped ones carrying `scope.model.display_name`.
        let payload = try jsonDictionary("""
        {
          "five_hour": {
            "utilization": 54.0,
            "resets_at": "2026-07-26T15:49:59.316047+00:00"
          },
          "seven_day": null,
          "seven_day_opus": null,
          "limits": [
            {
              "kind": "session",
              "group": "session",
              "percent": 54,
              "severity": "normal",
              "resets_at": "2026-07-26T15:49:59.316047+00:00",
              "scope": null,
              "is_active": true
            },
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 20,
              "severity": "normal",
              "resets_at": "2026-07-27T14:59:59.316297+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": false
            }
          ]
        }
        """)

        let snapshot = ClaudeCodeProvider().parseOAuthUsagePayloadForTesting(
            payload,
            authStatusJSON: #"{"email":"claude-user@example.com"}"#
        )

        #expect(snapshot.primary?.label == "5h")
        #expect(snapshot.primary?.used == 54)
        #expect(snapshot.secondary?.label == "7d·Fable")
        #expect(snapshot.secondary?.used == 20)
        #expect(snapshot.secondary?.resetAt != nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.isQuotaBlocked == false)
    }

    @Test("Claude OAuth usage limits array yields session window when five_hour is absent")
    func claudeOAuthUsageLimitsArraySessionFallback() throws {
        let payload = try jsonDictionary("""
        {
          "five_hour": null,
          "seven_day": null,
          "limits": [
            { "kind": "session", "group": "session", "percent": 87, "resets_at": "2026-07-26T15:49:59Z" },
            { "kind": "weekly", "group": "weekly", "percent": 41, "resets_at": "2026-07-27T14:59:59Z" },
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 12,
              "resets_at": "2026-07-27T14:59:59Z",
              "scope": { "model": { "display_name": "Fable" } }
            }
          ]
        }
        """)

        let snapshot = ClaudeCodeProvider().parseOAuthUsagePayloadForTesting(
            payload,
            authStatusJSON: #"{"email":"claude-user@example.com"}"#
        )

        #expect(snapshot.primary?.label == "5h")
        #expect(snapshot.primary?.used == 87)
        // All-models weekly ranks ahead of the model-scoped window.
        #expect(snapshot.secondary?.label == "7d")
        #expect(snapshot.secondary?.used == 41)
        #expect(snapshot.tertiary?.label == "7d·Fable")
        #expect(snapshot.tertiary?.used == 12)
    }

    @Test("Claude OAuth live snapshot marks active session limit without rewriting utilization")
    func claudeOAuthUsagePayloadMarksActiveRateLimitWithoutRewritingUsage() throws {
        // A Claude Code 429 can mean the current session is blocked, but the OAuth rolling-window
        // utilization is still the real quota percentage the panel and menu bar should display.
        let payload = try jsonDictionary("""
        {
          "five_hour": {
            "utilization": 71,
            "resets_at": "2026-06-29T11:50:00Z"
          },
          "seven_day": {
            "utilization": 12,
            "resets_at": "2026-07-04T09:00:00Z"
          }
        }
        """)
        let rateLimitLine = """
        {"type":"assistant","timestamp":"2026-06-29T10:40:27.000Z","message":{"content":[{"type":"text","text":"You've hit your session limit · resets 7:50pm (Asia/Shanghai)"}]},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}
        """

        let snapshot = ClaudeCodeProvider().parseOAuthUsagePayloadForTesting(
            payload,
            now: Date(timeIntervalSince1970: 1_782_730_800),
            rateLimitTranscriptLine: rateLimitLine
        )

        #expect(snapshot.primary?.used == 71)
        #expect(snapshot.isQuotaBlocked == true)
        #expect(snapshot.effectiveAvailabilityStatus == .sessionRateLimited)
        #expect(approximately(snapshot.statusBarMetric?.ratio, 0.29))
        #expect(snapshot.note == QuotaNoteCatalog.claudeRateLimitReached)
        // The weekly window is a separate limit and should keep its real utilization.
        #expect(snapshot.secondary?.used == 12)
    }

    @Test("Claude active rate limit keeps cached weekly window")
    func claudeActiveRateLimitKeepsCachedWeeklyWindow() {
        let provider = ClaudeCodeProvider()
        let resetAt = Date(timeIntervalSince1970: 1_782_736_800)
        let cached = QuotaSnapshot(
            source: "Claude Code OAuth Cache",
            accountIdentifier: "claude-user@example.com",
            planName: "Claude.ai",
            primary: QuotaWindow(label: "5h", used: 0, limit: 100, resetAt: nil),
            secondary: QuotaWindow(label: "7d", used: 15, limit: 100, resetAt: Date(timeIntervalSince1970: 1_783_242_000)),
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 1_782_730_000),
            note: QuotaNoteCatalog.claudeStaleLiveData(minutes: 7)
        )
        let event = ClaudeCodeProvider.ClaudeRateLimitEvent(
            resetAt: resetAt,
            capturedAt: Date(timeIntervalSince1970: 1_782_730_800),
            message: nil
        )

        let snapshot = provider.applyActiveRateLimit(
            to: cached,
            rateLimitEvent: event,
            now: Date(timeIntervalSince1970: 1_782_730_800)
        )

        #expect(snapshot.primary?.used == 100)
        #expect(snapshot.primary?.resetAt == resetAt)
        #expect(snapshot.secondary?.used == 15)
        #expect(snapshot.orderedMetrics.count == 2)
        #expect(snapshot.effectiveAvailabilityStatus == .sessionRateLimited)
    }

    @Test("Claude OAuth live snapshot keeps utilization when no active rate limit")
    func claudeOAuthUsagePayloadWithoutRateLimitKeepsUtilization() throws {
        let payload = try jsonDictionary("""
        {
          "five_hour": {
            "utilization": 71,
            "resets_at": "2026-06-29T11:50:00Z"
          }
        }
        """)

        let snapshot = ClaudeCodeProvider().parseOAuthUsagePayloadForTesting(
            payload,
            now: Date(timeIntervalSince1970: 1_782_730_800)
        )

        #expect(snapshot.primary?.used == 71)
        #expect(snapshot.isQuotaBlocked == false)
    }

    @Test("Provider notes localize into English and Traditional Chinese at render time")
    func quotaNotesLocalize() {
        let en = AppText(language: .english)
        let tc = AppText(language: .traditionalChinese)
        let sc = AppText(language: .simplifiedChinese)

        // Canonical (Simplified) note → localized per language. The Claude refresh slowdown note
        // stays quiet because QuotaBar retries automatically; sign-in errors are handled separately.
        #expect(en.localizedNote(QuotaNoteCatalog.claudeUsageRateLimited)?.contains("automatically") == true)
        #expect(tc.localizedNote(QuotaNoteCatalog.claudeUsageRateLimited)?.contains("自動重試") == true)
        #expect(sc.localizedNote(QuotaNoteCatalog.claudeUsageRateLimited) == QuotaNoteCatalog.claudeUsageRateLimited)
        #expect(sc.shouldDisplayNoteOnCard(QuotaNoteCatalog.claudeRateLimitReached) == false)
        #expect(sc.shouldDisplayNoteOnCard(QuotaNoteCatalog.claudeUsageRateLimited) == false)
        #expect(sc.shouldDisplayNoteOnCard(QuotaNoteCatalog.claudeWindowStale) == false)

        // Stale/expired-window note (shown when the frozen statusLine window is dropped).
        #expect(en.localizedNote(QuotaNoteCatalog.claudeWindowStale)?.contains("most recent") == true)
        #expect(tc.localizedNote(QuotaNoteCatalog.claudeWindowStale)?.contains("更新") == true)

        // Parameterized stale note keeps the minute count in every language.
        let stale = QuotaNoteCatalog.claudeStaleLiveData(minutes: 7)
        #expect(en.localizedNote(stale)?.contains("7 min") == true)
        #expect(tc.localizedNote(stale)?.contains("7 分鐘") == true)
        #expect(sc.localizedNote("暂时无法刷新，显示的是约 7 分钟前的额度。") == "显示约 7 分钟前的额度，稍后会自动更新。")
        #expect(sc.shouldDisplayNoteOnCard(stale) == false)
        #expect(sc.shouldDisplayNoteOnCard(QuotaNoteCatalog.claudeAwaitingSession) == true)

        // Cross-provider note also localizes.
        #expect(en.localizedNote(QuotaNoteCatalog.codexOAuthFellBackToApiKey)?.contains("API key") == true)
        #expect(en.shouldDisplayNoteOnCard(QuotaNoteCatalog.codexOAuthFellBackToApiKey) == false)

        // Unknown / composed (already language-neutral) notes pass through untouched.
        #expect(en.localizedNote("Included $8/$20 · On-demand $3") == "Included $8/$20 · On-demand $3")
        #expect(en.localizedNote(nil) == nil)
        #expect(en.localizedNote("   ") == nil)
    }

    @Test("Claude statusLine is fallback when live usage is unavailable")
    func claudeStatusLineIsFallbackWhenLiveUsageUnavailable() {
        let provider = ClaudeCodeProvider()
        let statusLine = QuotaSnapshot(
            source: "Claude Code StatusLine",
            accountIdentifier: "claude-user@example.com",
            planName: "Claude.ai",
            primary: QuotaWindow(label: "5h", used: 6, limit: 100, resetAt: nil),
            secondary: QuotaWindow(label: "7d", used: 8, limit: 100, resetAt: nil),
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 1_782_977_000),
            note: nil
        )
        let syncingStatusLine = QuotaSnapshot(
            source: "Claude Code StatusLine",
            accountIdentifier: "claude-user@example.com",
            planName: "Claude.ai",
            primary: nil,
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 1_782_978_000),
            note: QuotaNoteCatalog.claudeStatusLineNoWindows
        )
        let liveOAuth = QuotaSnapshot(
            source: "Claude Code OAuth",
            accountIdentifier: "claude-user@example.com",
            planName: "Claude.ai",
            primary: QuotaWindow(label: "5h", used: 2, limit: 100, resetAt: nil),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: Date(timeIntervalSince1970: 1_782_979_000),
            note: nil
        )

        #expect(provider.shouldUseStatusLineSnapshotAsPrimary(statusLine))
        #expect(!provider.shouldUseStatusLineSnapshotAsPrimary(syncingStatusLine))
        #expect(!provider.shouldUseStatusLineSnapshotAsPrimary(liveOAuth))

        let now = statusLine.updatedAt.addingTimeInterval(60)
        let staleLiveCache = liveOAuth.replacing(
            source: "Claude Code OAuth Cache",
            updatedAt: now.addingTimeInterval(-31 * 60)
        )
        #expect(provider.preferredClaudeSnapshot(
            liveSnapshot: liveOAuth,
            statusLineSnapshot: statusLine,
            hasUsableStatusLineSnapshot: true
        ).source == "Claude Code OAuth")
        let mergedLiveOAuth = provider.preferredClaudeSnapshot(
            liveSnapshot: liveOAuth,
            statusLineSnapshot: statusLine,
            hasUsableStatusLineSnapshot: true
        )
        #expect(mergedLiveOAuth.secondary?.used == 8)
        #expect(mergedLiveOAuth.orderedMetrics.count == 2)
        #expect(provider.preferredClaudeSnapshot(
            liveSnapshot: staleLiveCache,
            statusLineSnapshot: statusLine,
            hasUsableStatusLineSnapshot: true
        ).source == "Claude Code OAuth Cache")
        let recentCachedOAuth = liveOAuth.replacing(
            source: "Claude Code OAuth Cache",
            updatedAt: statusLine.updatedAt.addingTimeInterval(-30)
        )
        #expect(provider.preferredClaudeSnapshot(
            liveSnapshot: recentCachedOAuth,
            statusLineSnapshot: statusLine,
            hasUsableStatusLineSnapshot: true
        ).source == "Claude Code OAuth Cache")

        let blockedStatusLine = QuotaSnapshot(
            source: "Claude Code StatusLine",
            accountIdentifier: "claude-user@example.com",
            planName: "Claude.ai",
            primary: QuotaWindow(label: "5h", used: 100, limit: 100, resetAt: nil),
            secondary: nil,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: now.addingTimeInterval(-31 * 60),
            isQuotaBlocked: true,
            note: QuotaNoteCatalog.claudeRateLimitReached
        )
        #expect(provider.shouldUseStatusLineSnapshotAsPrimary(blockedStatusLine))
    }

    @Test("Claude statusLine drops an expired window instead of fabricating a value")
    func claudeStatusLinePayloadDropsExpiredWindows() throws {
        let status = try jsonDictionary("""
        {
          "rate_limits": {
            "five_hour": {
              "used_percentage": 8,
              "resets_at": 1782610800
            },
            "seven_day": {
              "used_percentage": 31,
              "resets_at": 1782637200
            }
          }
        }
        """)

        let now = Date(timeIntervalSince1970: 1_782_612_000)
        let snapshot = ClaudeCodeProvider().parseStatusLineSnapshotForTesting(
            status,
            capturedAt: Date(timeIntervalSince1970: 1_780_000_000),
            now: now
        )

        // The expired 5h window from a frozen statusLine is untrustworthy (could be idle-at-0 or
        // just stale while real usage climbed elsewhere), so it is dropped rather than fabricated —
        // never shown as the stale 8% nor invented as 0%/full. The fresh 7d window remains.
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.used == 31)
        #expect(snapshot.note == QuotaNoteCatalog.claudeWindowStale)
        #expect(QuotaFreshness.isStale(snapshot, now: now))
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

    private func approximately(_ value: Double?, _ expected: Double, tolerance: Double = 0.0001) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }
}
