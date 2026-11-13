import Foundation
import Testing

@testable import QuotaBarApp

@Suite("Quota HTTP client")
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

    struct RetryAfterCase: Sendable {
        let header: String?
        let now: TimeInterval
        let expected: TimeInterval?
    }

    @Test("Retry-After resolves numeric, date, and missing deadlines", arguments: [
        RetryAfterCase(header: "30", now: 1_000_000, expected: 1_000_030),
        RetryAfterCase(header: "Wed, 21 Oct 2026 07:28:00 GMT", now: 0, expected: 1_792_567_680),
        RetryAfterCase(header: nil, now: 1_000_000, expected: nil),
        RetryAfterCase(header: "   ", now: 1_000_000, expected: nil),
        RetryAfterCase(header: "Wed, 21 Oct 2020 07:28:00 GMT", now: 4_000_000_000, expected: 4_000_000_000)
    ])
    func retryAfterDeadline(testCase: RetryAfterCase) {
        let deadline = QuotaHTTPClient.retryAfterDeadline(
            from: response(retryAfter: testCase.header),
            now: Date(timeIntervalSince1970: testCase.now)
        )
        #expect(deadline == testCase.expected.map { Date(timeIntervalSince1970: $0) })
    }

    @Test("quota HTTP retry classification is shared")
    func quotaHTTPRetryClassification() {
        #expect(QuotaHTTPClient.isRetryableNetworkError(URLError(.timedOut)))
        #expect(!QuotaHTTPClient.isRetryableNetworkError(URLError(.badURL)))
        #expect(QuotaHTTPClient.isRetryableNetworkError(QuotaHTTPError(
            operation: "test",
            statusCode: 429,
            isRetryable: true
        )))
    }
}
