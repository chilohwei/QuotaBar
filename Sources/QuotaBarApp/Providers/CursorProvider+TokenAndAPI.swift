import Foundation

extension CursorProvider {
    func parseCredentials(_ secret: String) throws -> CursorCredentials {
        guard let data = secret.data(using: .utf8) else {
            throw ProviderError.credentialParsingFailed(tool: .cursor)
        }
        return try JSONDecoder().decode(CursorCredentials.self, from: data)
    }

    func cursorCredentialsRepresentSameAccount(_ lhs: CursorCredentials, _ rhs: CursorCredentials) -> Bool {
        let lhsEmail = cursorAccountEmail(from: lhs) ?? ""
        let rhsEmail = cursorAccountEmail(from: rhs) ?? ""
        if !lhsEmail.isEmpty || !rhsEmail.isEmpty {
            return !lhsEmail.isEmpty && lhsEmail == rhsEmail
        }

        let lhsSubject = jwtStringClaim(lhs.accessToken, claim: "sub")
        let rhsSubject = jwtStringClaim(rhs.accessToken, claim: "sub")
        if let lhsSubject, let rhsSubject {
            return lhsSubject == rhsSubject
        }

        return lhs.accessToken == rhs.accessToken
    }

    func normalizeIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func encodeCredentials(_ credentials: CursorCredentials) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(credentials) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func shouldRefreshAccessToken(_ credentials: CursorCredentials) -> Bool {
        guard let refreshToken = credentials.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expiresAt = jwtExpirationDate(credentials.accessToken) else {
            return false
        }
        return expiresAt.timeIntervalSinceNow < 10 * 60
    }

    func refreshAccessToken(credentials: CursorCredentials) async throws -> String {
        guard let refreshToken = credentials.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encodeCredentials(credentials)
        }

        var request = URLRequest(url: apiBaseURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB",
            "refresh_token": refreshToken
        ])

        let data = try await dataWithRetry(for: request, operation: "Cursor token 刷新")
        let response = try JSONDecoder().decode(CursorTokenRefreshResponse.self, from: data)
        if response.shouldLogout == true {
            throw ProviderError.tokenExpired(tool: .cursor)
        }
        guard let accessToken = response.accessToken,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.tokenRefreshFailed(tool: .cursor)
        }

        let refreshed = CursorCredentials(
            accessToken: accessToken,
            refreshToken: credentials.refreshToken,
            email: credentials.email,
            membershipType: credentials.membershipType,
            subscriptionStatus: credentials.subscriptionStatus,
            subscriptionPeriodEnd: credentials.subscriptionPeriodEnd,
            stateDatabasePath: credentials.stateDatabasePath,
            source: credentials.source
        )
        return encodeCredentials(refreshed)
    }

    func jwtExpirationDate(_ token: String) -> Date? {
        guard let exp = jwtDoubleClaim(token, claim: "exp") else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    func jwtStringClaim(_ token: String, claim: String) -> String? {
        jwtPayload(token)?[claim] as? String
    }

    func jwtDoubleClaim(_ token: String, claim: String) -> Double? {
        guard let value = jwtPayload(token)?[claim] else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    func fetchCurrentPeriodUsage(accessToken: String) async throws -> Any {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("aiserver.v1.DashboardService/GetCurrentPeriodUsage"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        let data = try await dataWithRetry(for: request, operation: "Cursor 当前周期用量查询")
        return try JSONSerialization.jsonObject(with: data)
    }

    func fetchLegacyUsage(accessToken: String) async throws -> Any {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("auth/usage"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await dataWithRetry(for: request, operation: "Cursor legacy 用量查询")
        return try JSONSerialization.jsonObject(with: data)
    }

}
