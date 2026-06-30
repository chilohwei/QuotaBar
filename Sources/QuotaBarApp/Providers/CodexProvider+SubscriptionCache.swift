import Foundation

extension CodexProvider {
    struct SubscriptionCacheMetadata {
        let planName: String?
        let billingCycle: String?
        let accountValidUntil: Date?
        let subscriptionWillRenew: Bool?
        let subscriptionStatus: String?
        let fetchedAt: Date?
    }

    func loadSubscriptionCacheMetadata(
        accountKey: String?,
        accountID: String?,
        email: String?
    ) -> SubscriptionCacheMetadata? {
        guard fileService.fileExists(at: subscriptionsCachePath),
              let cache = try? loadJSONDictionary(at: subscriptionsCachePath),
              let entry = subscriptionCacheEntry(in: cache, accountKey: accountKey, accountID: accountID, email: email) else {
            return nil
        }

        let planName = firstString(
            in: entry,
            keys: ["plan_name", "planName", "plan", "chatgpt_plan_type", "chatgptPlanType"]
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let billingCycle = firstString(
            in: entry,
            keys: ["billing_cycle", "billingCycle", "cycle", "interval"]
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let subscriptionStatus = firstString(
            in: entry,
            keys: ["subscription_status", "subscriptionStatus", "status"]
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return SubscriptionCacheMetadata(
            planName: (planName?.isEmpty == false) ? planName : nil,
            billingCycle: (billingCycle?.isEmpty == false) ? billingCycle : nil,
            accountValidUntil: findDate(
                in: entry,
                keys: ["account_valid_until", "accountValidUntil", "valid_until", "validUntil", "current_period_end", "currentPeriodEnd"]
            ),
            subscriptionWillRenew: firstBool(in: entry, keys: ["subscription_will_renew", "subscriptionWillRenew", "will_renew", "willRenew"]),
            subscriptionStatus: (subscriptionStatus?.isEmpty == false) ? subscriptionStatus : nil,
            fetchedAt: findDate(
                in: entry,
                keys: ["fetched_at", "fetchedAt", "updated_at", "updatedAt", "updated_at_ms", "updatedAtMs"]
            )
        )
    }

    func subscriptionCacheEntry(
        in cache: [String: Any],
        accountKey: String?,
        accountID: String?,
        email: String?
    ) -> [String: Any]? {
        let normalizedAccountKey = normalizedRegistryKey(accountKey)?.lowercased()
        let normalizedAccountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let accounts = cache["accounts"] as? [String: Any] {
            for (key, value) in accounts {
                guard let entry = value as? [String: Any] else { continue }
                if key.lowercased() == normalizedAccountKey
                    || key.lowercased() == normalizedAccountID
                    || key.lowercased() == normalizedEmail
                    || subscriptionEntry(entry, matchesAccountKey: normalizedAccountKey, accountID: normalizedAccountID, email: normalizedEmail) {
                    return entry
                }
            }
        }

        if let accounts = cache["accounts"] as? [[String: Any]] {
            return accounts.first {
                subscriptionEntry($0, matchesAccountKey: normalizedAccountKey, accountID: normalizedAccountID, email: normalizedEmail)
            }
        }

        if subscriptionEntry(cache, matchesAccountKey: normalizedAccountKey, accountID: normalizedAccountID, email: normalizedEmail) {
            return cache
        }

        return nil
    }

    func subscriptionEntry(
        _ entry: [String: Any],
        matchesAccountKey accountKey: String?,
        accountID: String?,
        email: String?
    ) -> Bool {
        let entryAccountKey = firstString(in: entry, keys: ["account_key", "accountKey"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let entryAccountID = firstString(in: entry, keys: ["chatgpt_account_id", "chatgptAccountId", "account_id", "accountId"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let entryEmail = firstString(in: entry, keys: ["email", "account_email", "accountEmail"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return (accountKey?.isEmpty == false && entryAccountKey == accountKey)
            || (accountID?.isEmpty == false && entryAccountID == accountID)
            || (email?.isEmpty == false && entryEmail == email)
    }

    func storeSubscriptionCache(
        _ snapshot: QuotaSnapshot,
        accountKey: String?,
        accountID: String?,
        email: String?
    ) throws {
        let metadata = SubscriptionCacheMetadata(
            planName: snapshot.planName,
            billingCycle: nil,
            accountValidUntil: snapshot.accountValidUntil,
            subscriptionWillRenew: snapshot.subscriptionWillRenew,
            subscriptionStatus: snapshot.subscriptionStatus,
            fetchedAt: snapshot.updatedAt
        )
        try storeSubscriptionCache(metadata, accountKey: accountKey, accountID: accountID, email: email)
    }

    func storeSubscriptionCache(
        _ metadata: SubscriptionCacheMetadata,
        accountKey: String?,
        accountID: String?,
        email: String?
    ) throws {
        let planName = metadata.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSubscriptionDetails = planName?.isEmpty == false
            || metadata.accountValidUntil != nil
            || metadata.subscriptionWillRenew != nil
            || metadata.subscriptionStatus?.isEmpty == false
        guard hasSubscriptionDetails else { return }

        let storageKey = normalizedRegistryKey(accountKey)
            ?? accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let storageKey, !storageKey.isEmpty else { return }

        try fileService.createDirectoryIfNeeded(at: accountsDirectoryPath)
        var cache = (try? loadJSONDictionary(at: subscriptionsCachePath)) ?? [
            "schema_version": 1,
            "accounts": [String: Any]()
        ]
        var accounts = cache["accounts"] as? [String: Any] ?? [:]
        var entry = accounts[storageKey] as? [String: Any] ?? [:]
        let nowMilliseconds = Int(Date().timeIntervalSince1970 * 1000)

        entry["account_key"] = normalizedRegistryKey(accountKey)
        entry["chatgpt_account_id"] = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry["email"] = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        entry["plan_name"] = planName
        entry["billing_cycle"] = metadata.billingCycle?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry["account_valid_until"] = metadata.accountValidUntil.map { ISO8601DateFormatter().string(from: $0) }
        entry["subscription_will_renew"] = metadata.subscriptionWillRenew
        entry["subscription_status"] = metadata.subscriptionStatus
        entry["fetched_at"] = Int64((metadata.fetchedAt ?? Date()).timeIntervalSince1970)
        entry["updated_at_ms"] = nowMilliseconds

        accounts[storageKey] = entry
        cache["schema_version"] = cache["schema_version"] ?? 1
        cache["accounts"] = accounts
        cache["updated_at_ms"] = nowMilliseconds

        try writeJSONDictionary(cache, to: subscriptionsCachePath, backup: true)
    }

    func removeStoredSubscription(accountKey: String) throws {
        guard fileService.fileExists(at: subscriptionsCachePath) else { return }
        var cache = try loadJSONDictionary(at: subscriptionsCachePath)
        guard var accounts = cache["accounts"] as? [String: Any],
              accounts.removeValue(forKey: accountKey) != nil else {
            return
        }
        cache["accounts"] = accounts
        cache["updated_at_ms"] = Int(Date().timeIntervalSince1970 * 1000)
        try writeJSONDictionary(cache, to: subscriptionsCachePath, backup: true)
    }
}
