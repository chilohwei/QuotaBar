import CryptoKit
import Foundation

extension CursorProvider {
    struct CursorOAuthLoginSession {
        let uuid: String
        let verifier: String
        let challenge: String
    }

    struct CursorOAuthPollResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let authId: String?
    }

    private struct CursorEmailResponse: Decodable {
        let email: String?
    }

    func makeCursorOAuthLoginSession() -> CursorOAuthLoginSession {
        let randomBytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }
        let verifier = base64URLEncodedString(Data(randomBytes))
        let challenge = base64URLEncodedString(Data(SHA256.hash(data: Data(verifier.utf8))))
        return CursorOAuthLoginSession(
            uuid: UUID().uuidString.lowercased(),
            verifier: verifier,
            challenge: challenge
        )
    }

    func cursorOAuthLoginPageURL(session: CursorOAuthLoginSession) -> URL? {
        var components = URLComponents(string: "https://www.cursor.com/loginDeepControl")
        components?.queryItems = [
            URLQueryItem(name: "challenge", value: session.challenge),
            URLQueryItem(name: "uuid", value: session.uuid),
            URLQueryItem(name: "mode", value: "login")
        ]
        return components?.url
    }

    func openCursorOAuthLoginPage(session: CursorOAuthLoginSession) throws {
        guard let url = cursorOAuthLoginPageURL(session: session) else {
            throw ProviderError.unsupported("无法构造 Cursor 登录链接")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
    }

    func pollCursorOAuthCredentials(session: CursorOAuthLoginSession) async throws -> CursorCredentials? {
        var components = URLComponents(
            url: apiBaseURL.appendingPathComponent("auth/poll"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "uuid", value: session.uuid),
            URLQueryItem(name: "verifier", value: session.verifier)
        ]
        guard let url = components?.url else {
            throw ProviderError.unsupported("无法构造 Cursor 登录轮询链接")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // The poll endpoint returns a non-200 status until the user finishes authorizing.
            return nil
        }
        return cursorOAuthCredentials(fromPollData: data)
    }

    func cursorOAuthCredentials(fromPollData data: Data) -> CursorCredentials? {
        guard let decoded = try? JSONDecoder().decode(CursorOAuthPollResponse.self, from: data),
              let accessToken = decoded.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }

        let refreshToken = decoded.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CursorCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken?.isEmpty == false ? refreshToken : nil,
            email: nil,
            membershipType: nil,
            subscriptionStatus: nil,
            subscriptionPeriodEnd: nil,
            stateDatabasePath: nil,
            source: "cursorOAuth"
        )
    }

    func fetchCursorAccountEmail(accessToken: String) async -> String? {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("aiserver.v1.AuthService/GetEmail"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        guard let data = try? await dataWithRetry(for: request, operation: "Cursor 账号邮箱查询"),
              let decoded = try? JSONDecoder().decode(CursorEmailResponse.self, from: data),
              let email = decoded.email.flatMap({ emailAddress(in: $0) }) else {
            return nil
        }
        return email
    }

    func base64URLEncodedString(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
