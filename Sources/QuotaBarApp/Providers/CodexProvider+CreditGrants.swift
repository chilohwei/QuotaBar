import Foundation

extension CodexProvider {
    func fetchCreditGrants(apiKey: String, note: String?) async throws -> QuotaSnapshot {
        let url = URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await dataWithRetry(for: request, operation: "OpenAI credit_grants 查询")

        let payload = try JSONSerialization.jsonObject(with: data)
        guard let dict = payload as? [String: Any] else {
            throw ProviderError.network("OpenAI credit_grants 返回格式异常")
        }

        let totalGranted = JSONObjectPath.findDouble(in: dict, keys: ["total_granted", "grant_amount"])
        let totalUsed = JSONObjectPath.findDouble(in: dict, keys: ["total_used", "used_amount"])
        let totalAvailable = JSONObjectPath.findDouble(in: dict, keys: ["total_available", "available_amount"])

        let resolvedTotal: Double?
        let resolvedRemaining: Double?

        if let totalGranted {
            resolvedTotal = totalGranted
            if let totalAvailable {
                resolvedRemaining = totalAvailable
            } else if let totalUsed {
                resolvedRemaining = max(totalGranted - totalUsed, 0)
            } else {
                resolvedRemaining = nil
            }
        } else if let totalAvailable, let totalUsed {
            resolvedTotal = totalAvailable + totalUsed
            resolvedRemaining = totalAvailable
        } else {
            resolvedTotal = nil
            resolvedRemaining = nil
        }

        return QuotaSnapshot(
            source: "OpenAI API Key",
            planName: "API Key",
            primary: nil,
            secondary: nil,
            creditsRemaining: resolvedRemaining,
            creditsTotal: resolvedTotal,
            updatedAt: .init(),
            note: note
        )
    }
}
