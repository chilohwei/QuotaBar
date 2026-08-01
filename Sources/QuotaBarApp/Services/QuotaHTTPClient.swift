import Foundation

struct QuotaHTTPError: LocalizedError, Sendable {
    let operation: String
    let statusCode: Int
    let isRetryable: Bool
    let retryAfter: Date?

    init(operation: String, statusCode: Int, isRetryable: Bool, retryAfter: Date? = nil) {
        self.operation = operation
        self.statusCode = statusCode
        self.isRetryable = isRetryable
        self.retryAfter = retryAfter
    }

    var errorDescription: String? {
        switch statusCode {
        case 401:
            return "登录已过期，请重新登录"
        case 403:
            return "访问被拒绝，请检查账号状态"
        case 429:
            return "请求过于频繁，稍后自动重试"
        case 500...599:
            return "服务器暂时不可用，稍后自动重试"
        default:
            return "请求失败（\(statusCode)），稍后重试"
        }
    }
}

struct QuotaHTTPClient: Sendable {
    private let session: URLSession
    private let maxAttempts: Int

    /// Shared session with a bounded per-request timeout. `URLSession.shared` leaves the request
    /// timeout at 60s — long enough to stall a menu-bar refresh on a hung provider endpoint — so
    /// a 20s cap fails fast into the existing retry/backoff path instead. Cookie and cache
    /// behaviour matches the process default, so this only tightens timeouts; callers that need
    /// isolation (Codex) still inject their own session.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration)
    }()

    init(session: URLSession = QuotaHTTPClient.defaultSession, maxAttempts: Int = 3) {
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
                    isRetryable: retryable,
                    retryAfter: Self.retryAfterDeadline(from: http)
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

    static func retryAfterDeadline(from response: HTTPURLResponse?, now: Date = Date()) -> Date? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        if let date = HTTPDateFormatter.shared.date(from: raw) {
            return max(date, now)
        }
        return nil
    }

    private func retryAfterSeconds(from response: HTTPURLResponse?) -> Double? {
        guard let deadline = Self.retryAfterDeadline(from: response) else { return nil }
        return min(max(deadline.timeIntervalSinceNow, 0), 30)
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
