import Foundation

extension CodexProvider {
    static let resetCreditsSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        return URLSession(configuration: configuration)
    }()

    func makeResetCreditsRequest(accessToken: String, accountID: String?) -> URLRequest {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
        var request = makeOAuthUsageRequest(url: url, accessToken: accessToken, accountID: accountID)
        request.timeoutInterval = 4
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        return request
    }

    func fetchResetCredits(accessToken: String, accountID: String?, session: URLSession = CodexProvider.resetCreditsSession) async -> QuotaResetCredits? {
        let request = makeResetCreditsRequest(accessToken: accessToken, accountID: accountID)
        do {
            // Optional inventory has one bounded attempt, independent of quota retries.
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { return nil }
            return try QuotaResetCredits.parse(data)
        } catch {
            return nil
        }
    }
}
