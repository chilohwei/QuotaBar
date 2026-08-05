import Foundation

extension CursorProvider {
    func parseLegacyUsage(_ payload: Any, credentials: CursorCredentials) -> QuotaSnapshot {
        let windows = UsageWindowExtractor.extract(from: payload)
        let sorted = windows.sorted { ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture) }
        let periodEnd = firstDate(in: payload, keys: Self.cycleBoundaryDateKeys)
            ?? sorted.compactMap(\.resetAt).max()

        return QuotaSnapshot(
            source: "Cursor Legacy",
            accountIdentifier: cursorAccountEmail(from: credentials),
            planName: normalizedPlanName(credentials.membershipType),
            primary: sorted.first,
            secondary: sorted.dropFirst().first,
            tertiary: sorted.dropFirst(2).first,
            creditsRemaining: nil,
            creditsTotal: nil,
            updatedAt: .init(),
            periodEnd: periodEnd,
            accountValidUntil: credentials.subscriptionPeriodEnd,
            subscriptionWillRenew: inferSubscriptionWillRenew(from: credentials.subscriptionStatus),
            subscriptionStatus: normalizedSubscriptionStatus(credentials.subscriptionStatus),
            note: sorted.isEmpty ? QuotaNoteCatalog.cursorLegacyNoStandardFields : nil
        )
    }

    func parsePercentWindow(label: String, usedPercent: Double?, resetAt: Date?) -> QuotaWindow? {
        guard var usedPercent else { return nil }
        if usedPercent <= 1 {
            usedPercent *= 100
        }
        return QuotaWindow(label: label, used: min(max(usedPercent, 0), 100), limit: 100, resetAt: resetAt)
    }

    func normalizedSubscriptionStatus(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    func inferSubscriptionWillRenew(from status: String?) -> Bool? {
        guard let status = normalizedSubscriptionStatus(status) else { return nil }
        switch status {
        case "active", "trialing", "paid":
            return true
        case "canceled", "cancelled", "incomplete_expired", "expired", "unpaid", "past_due":
            return false
        default:
            return nil
        }
    }

    func cursorUsageNote(
        plan: [String: Any]?,
        onDemand: [String: Any]?,
        spendLimit: [String: Any]? = nil
    ) -> String? {
        var parts: [String] = []
        if let included = includedPlanSpendNote(plan: plan) {
            parts.append(included)
        }

        let onDemandSources = [onDemand, spendLimit].compactMap { $0 }
        for source in onDemandSources {
            if let window = parseSpendLimitOnDemandWindow(source, resetAt: nil) {
                parts.append("On-demand \(formatDollars(window.used))/\(formatDollars(window.limit))")
                break
            }
            if firstBool(in: source, keys: ["enabled"]) == true,
               let used = directDouble(in: source, keys: ["totalSpend", "total_spend"])
                ?? directDouble(in: source, keys: ["individualUsed", "individual_used"])
                ?? directDouble(in: source, keys: ["pooledUsed", "pooled_used"]),
               used > 0 {
                let limit = directDouble(in: source, keys: ["individualLimit", "individual_limit"])
                    ?? directDouble(in: source, keys: ["pooledLimit", "pooled_limit"])
                if let limit, limit > 0 {
                    parts.append("On-demand \(formatDollars(used))/\(formatDollars(limit))")
                } else {
                    parts.append("On-demand \(formatDollars(used))")
                }
                break
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func formatDollars(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }

    func normalizedPlanName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case let value where value.contains("ultra"):
            return "Ultra"
        case let value where value.contains("pro_plus") || value.contains("pro plus") || value.contains("pro+"):
            return "Pro+"
        case let value where value.contains("pro"):
            return "Pro"
        case let value where value.contains("team") || value.contains("business"):
            return "Team"
        case let value where value.contains("enterprise"):
            return "Enterprise"
        case let value where value.contains("free") || value.contains("hobby"):
            return "Free"
        default:
            return raw
        }
    }

    func isFreeCursorPlan(_ planName: String?) -> Bool {
        guard let planName = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !planName.isEmpty else {
            return false
        }
        return planName.contains("free") || planName.contains("hobby")
    }

    func isQuotaBlocked(in payload: Any) -> Bool? {
        firstBool(in: payload, keys: ["isBlocked", "is_blocked", "limitReached", "limit_reached", "isHardLimited", "is_hard_limited"])
    }

    func dataWithRetry(for request: URLRequest, operation: String) async throws -> Data {
        try await Self.httpClient.data(for: request, operation: operation)
    }

    func isRetryableNetworkError(_ error: Error) -> Bool {
        QuotaHTTPClient.isRetryableNetworkError(error)
    }

    func shouldUseCachedQuota(for error: Error) -> Bool {
        isRetryableNetworkError(error)
    }

    func quotaCacheKey(_ credentials: CursorCredentials) -> String {
        let raw = accountIdentity(from: encodeCredentials(credentials)) ?? String(credentials.accessToken.suffix(24))
        return "cursor-" + base64URLEncodedString(Data(raw.utf8))
    }

    func quotaCachePath(cacheKey: String) -> String {
        AppPaths.quotaCacheDirectory.appendingPathComponent("\(cacheKey).json").path
    }

    func loadCachedQuotaSnapshot(cacheKey: String) throws -> CachedQuotaSnapshot {
        let text = try fileService.readText(at: quotaCachePath(cacheKey: cacheKey))
        guard let data = text.data(using: .utf8) else {
            throw ProviderError.cacheCorrupted(tool: .cursor)
        }
        return try JSONDecoder().decode(CachedQuotaSnapshot.self, from: data)
    }

    func storeQuotaSnapshot(_ snapshot: QuotaSnapshot, cacheKey: String) throws {
        try fileService.createDirectoryIfNeeded(at: AppPaths.quotaCacheDirectory.path)
        let cached = CachedQuotaSnapshot(schemaVersion: 1, cachedAt: .init(), snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cached)
        try fileService.writeText(
            String(data: data, encoding: .utf8) ?? "{}",
            to: quotaCachePath(cacheKey: cacheKey),
            permissions: 0o600
        )
    }

    func mergedNote(_ existing: String?, fallback: String) -> String {
        guard let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines),
              !existing.isEmpty else {
            return fallback
        }
        if existing.contains(fallback) {
            return existing
        }
        return "\(existing)；\(fallback)"
    }

}
