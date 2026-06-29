import Foundation

struct QuotaHTTPError: LocalizedError, Sendable {
    let operation: String
    let statusCode: Int
    let isRetryable: Bool

    var errorDescription: String? {
        "\(operation) 失败，HTTP \(statusCode)"
    }
}

struct QuotaHTTPClient: Sendable {
    private let session: URLSession
    private let maxAttempts: Int

    init(session: URLSession = .shared, maxAttempts: Int = 3) {
        self.session = session
        self.maxAttempts = max(maxAttempts, 1)
    }

    func data(for request: URLRequest, operation: String) async throws -> Data {
        var lastError: Error?

        for attempt in 0 ..< maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ProviderError.network("\(operation)失败：无 HTTP 响应")
                }

                if 200 ..< 300 ~= http.statusCode {
                    return data
                }

                let retryable = Self.isRetryableHTTPStatus(http.statusCode)
                let failure = QuotaHTTPError(
                    operation: operation,
                    statusCode: http.statusCode,
                    isRetryable: retryable
                )
                guard retryable, attempt < maxAttempts - 1 else {
                    throw failure
                }
                lastError = failure
                try await sleepBeforeRetry(attempt: attempt, response: http)
            } catch {
                if error is CancellationError {
                    throw error
                }
                guard Self.isRetryableNetworkError(error), attempt < maxAttempts - 1 else {
                    throw error
                }
                lastError = error
                try await sleepBeforeRetry(attempt: attempt, response: nil)
            }
        }

        throw lastError ?? ProviderError.network("\(operation)失败")
    }

    static func isRetryableNetworkError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let failure = error as? QuotaHTTPError {
            return failure.isRetryable
        }

        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return true
        default:
            return false
        }
    }

    private static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 409
            || statusCode == 425
            || statusCode == 429
            || (500 ... 599).contains(statusCode)
    }

    private func sleepBeforeRetry(attempt: Int, response: HTTPURLResponse?) async throws {
        let seconds = retryAfterSeconds(from: response) ?? defaultRetryDelaySeconds(for: attempt)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func retryAfterSeconds(from response: HTTPURLResponse?) -> Double? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw), seconds >= 0 {
            return min(seconds, 30)
        }
        if let date = HTTPDateFormatter.shared.date(from: raw) {
            return min(max(date.timeIntervalSinceNow, 0), 30)
        }
        return nil
    }

    private func defaultRetryDelaySeconds(for attempt: Int) -> Double {
        [0.35, 0.9, 1.8][min(attempt, 2)]
    }
}

private final class HTTPDateFormatter: @unchecked Sendable {
    static let shared = HTTPDateFormatter()

    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()

    func date(from raw: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: raw)
    }
}
