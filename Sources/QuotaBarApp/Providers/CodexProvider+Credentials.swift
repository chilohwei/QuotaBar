import Foundation

extension CodexProvider {
    struct CodexCredentials {
        let apiKey: String?
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?
        let accountID: String?
        let lastRefresh: Date?
    }

    func parseCredentialEnvelope(data: Data) throws -> (root: [String: Any], credentials: CodexCredentials) {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any] else {
            throw ProviderError.credentialParsingFailed(tool: .codex)
        }

        let apiKey = (dict["OPENAI_API_KEY"] as? String)
            ?? (dict["openai_api_key"] as? String)
            ?? (dict["openaiApiKey"] as? String)
        let tokens = dict["tokens"] as? [String: Any]
        let accessToken = stringValue(in: tokens, snakeKey: "access_token", camelKey: "accessToken")
            ?? stringValue(in: dict, snakeKey: "access_token", camelKey: "accessToken")
        let refreshToken = stringValue(in: tokens, snakeKey: "refresh_token", camelKey: "refreshToken")
            ?? stringValue(in: dict, snakeKey: "refresh_token", camelKey: "refreshToken")
        let idToken = stringValue(in: tokens, snakeKey: "id_token", camelKey: "idToken")
            ?? stringValue(in: dict, snakeKey: "id_token", camelKey: "idToken")
        let accountID = stringValue(in: tokens, snakeKey: "account_id", camelKey: "accountId")
            ?? stringValue(in: dict, snakeKey: "account_id", camelKey: "accountId")
        let credentials = CodexCredentials(
            apiKey: apiKey,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            lastRefresh: parseLastRefresh(dict["last_refresh"])
        )
        return (dict, credentials)
    }

    func parseCredentials(data: Data) throws -> CodexCredentials {
        try parseCredentialEnvelope(data: data).credentials
    }
}
