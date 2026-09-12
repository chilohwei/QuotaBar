import Foundation
import Testing
@testable import QuotaBarApp

struct ResetCreditsTests {
    let now = Date(timeIntervalSince1970: 1_788_134_400)

    @Test func parsesAvailableInventoryAndExpiryFormats() throws {
        let data = Data(#"{"available_count":2,"credits":[{"reset_type":"codex_rate_limits","status":"available","expires_at":"2026-07-18T00:39:53.731630Z"},{"reset_type":"codex_rate_limits","status":"available","expires_at":null},{"reset_type":"codex_rate_limits","status":"redeemed","expires_at":"2026-07-12T00:00:00Z"},{"reset_type":"codex_rate_limits","status":"future_status","expires_at":null}]}"#.utf8)
        let inventory = try QuotaResetCredits.parse(data, now: now)
        #expect(inventory.availableCount == 2)
        #expect(inventory.credits.count == 2)
        #expect(inventory.availableCredits(at: now).last?.expiresAt == nil)
        #expect(inventory.updatedAt == now)
    }

    @Test func unknownMalformedAndZeroAreDistinct() throws {
        for payload in [#"{}"#, #"{"available_count":-1,"credits":[]}"#, #"{"available_count":1,"credits":[{"reset_type":"codex_rate_limits","status":"available","expires_at":"bad"}]}"#] {
            #expect(throws: (any Error).self) { try QuotaResetCredits.parse(Data(payload.utf8)) }
        }
        #expect(try QuotaResetCredits.parse(Data(#"{"available_count":0,"credits":[]}"#.utf8)).availableCount == 0)
    }

    @Test func expirationDoesNotDoubleSubtractOrInventMissingCredits() {
        let inventory = QuotaResetCredits(availableCount: 3, credits: [
            .init(expiresAt: now.addingTimeInterval(-1)),
            .init(expiresAt: now.addingTimeInterval(10)),
            .init(expiresAt: nil)
        ], updatedAt: now)
        #expect(inventory.remainingCount(at: now) == 3)
        #expect(inventory.remainingCount(at: now.addingTimeInterval(10)) == 2)
        #expect(inventory.availableCredits(at: now.addingTimeInterval(10)).count == 1)
    }

    @Test func requestUsesSameAccountAndReadOnlyEndpoint() {
        let request = CodexProvider().makeResetCreditsRequest(accessToken: "test-only", accountID: "account-a")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/backend-api/wham/rate-limit-reset-credits")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-a")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
        #expect(request.timeoutInterval == 4)
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func inventorySurvivesCacheAndSnapshotReplacement() throws {
        let inventory = QuotaResetCredits(availableCount: 2, credits: [.init(expiresAt: nil)], updatedAt: now)
        let snapshot = QuotaSnapshot(source: "Codex OAuth", primary: .init(label: "5h", used: 10, limit: 100, resetAt: now.addingTimeInterval(-1000)), secondary: nil, creditsRemaining: nil, creditsTotal: nil, resetCredits: inventory, updatedAt: now, note: nil)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.resetCredits == inventory)
        #expect(decoded.replacing(source: "Codex OAuth Cache").resetCredits == inventory)
        #expect(decoded.removingExpiredWindows(now: now).resetCredits == inventory)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        old.removeValue(forKey: "resetCredits")
        #expect(try JSONDecoder().decode(QuotaSnapshot.self, from: JSONSerialization.data(withJSONObject: old)).resetCredits == nil)
    }
}

private final class ResetCreditURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization")
        let status = token == "Bearer failure" ? 503 : 200
        let body = token == "Bearer malformed" ? "{}" : #"{"available_count":0,"credits":[]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ResetCreditsTests {
    @Test func optionalQueryDistinguishesFailedFetchFromConfirmedZero() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetCreditURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = CodexProvider()
        #expect(await provider.fetchResetCredits(accessToken: "failure", accountID: "test", session: session) == nil)
        #expect(await provider.fetchResetCredits(accessToken: "malformed", accountID: "test", session: session) == nil)
        #expect(await provider.fetchResetCredits(accessToken: "zero", accountID: "test", session: session)?.availableCount == 0)
    }
}
