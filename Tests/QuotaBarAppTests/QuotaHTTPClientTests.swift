import Foundation
import Testing

@testable import QuotaBarApp

@Suite("QuotaHTTPClient Retry-After")
struct QuotaHTTPClientTests {
    private func response(retryAfter: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let retryAfter {
            headers["Retry-After"] = retryAfter
        }
        return HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    @Test("numeric Retry-After is interpreted as delta seconds")
    func numericRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let deadline = QuotaHTTPClient.retryAfterDeadline(from: response(retryAfter: "30"), now: now)
        #expect(deadline == now.addingTimeInterval(30))
    }

    @Test("future HTTP-date Retry-After parses to that instant")
    func httpDateRetryAfter() {
        let now = Date(timeIntervalSince1970: 0)
        let deadline = QuotaHTTPClient.retryAfterDeadline(
            from: response(retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT"),
            now: now
        )
        #expect(deadline != nil)
        #expect(deadline! > now)
    }

    @Test("missing or blank Retry-After yields no deadline")
    func missingRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(QuotaHTTPClient.retryAfterDeadline(from: response(retryAfter: nil), now: now) == nil)
        #expect(QuotaHTTPClient.retryAfterDeadline(from: response(retryAfter: "   "), now: now) == nil)
    }

    @Test("a past HTTP-date is clamped to now, never the past")
    func pastDateClamped() {
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let deadline = QuotaHTTPClient.retryAfterDeadline(
            from: response(retryAfter: "Wed, 21 Oct 2020 07:28:00 GMT"),
            now: now
        )
        #expect(deadline == now)
    }
}
