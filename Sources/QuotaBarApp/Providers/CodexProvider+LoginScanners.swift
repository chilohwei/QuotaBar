import Foundation

struct CodexUsageIdentity {
    let email: String?
    let userID: String?
    let accountID: String?
}

struct CodexDeviceAuthPrompt: Sendable {
    let url: URL
    let code: String
}

final class CodexLoginFallbackURLScanner: @unchecked Sendable {
    let lock = NSLock()
    var buffer = ""
    var didFindURL = false

    func append(_ data: Data) -> URL? {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        guard !didFindURL else { return nil }
        buffer += text
        if buffer.count > 8_000 {
            buffer = String(buffer.suffix(8_000))
        }

        guard Self.containsBrowserOpenFailure(in: buffer),
              let url = Self.extractFirstExternalLoginURL(from: buffer) else {
            return nil
        }

        didFindURL = true
        return url
    }

    static func containsBrowserOpenFailure(in text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("failed to open browser")
            || normalized.contains("failed to open login url")
            || normalized.contains("failed to open browser for login url")
    }

    static func extractFirstExternalLoginURL(from text: String) -> URL? {
        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let trailingPunctuation = CharacterSet(charactersIn: ".,;:)]}")

        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let rawURL = String(text[matchRange]).trimmingCharacters(in: trailingPunctuation)
            guard let url = URL(string: rawURL),
                  isExternalLoginURL(url) else {
                continue
            }
            return url
        }

        return nil
    }

    static func isExternalLoginURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }

        if host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host.hasSuffix(".localhost") {
            return false
        }

        return host == "auth.openai.com"
            || host.hasSuffix(".auth.openai.com")
            || host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
            || host == "openai.com"
            || host.hasSuffix(".openai.com")
    }
}

final class CodexDeviceAuthPromptScanner: @unchecked Sendable {
    let lock = NSLock()
    var buffer = ""
    var didPresent = false

    func append(_ data: Data) -> CodexDeviceAuthPrompt? {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        guard !didPresent else { return nil }
        buffer += text.strippingANSIControlSequences()
        if buffer.count > 8_000 {
            buffer = String(buffer.suffix(8_000))
        }

        guard let url = Self.extractDeviceAuthURL(from: buffer),
              let code = Self.extractDeviceCode(from: buffer) else {
            return nil
        }

        didPresent = true
        return CodexDeviceAuthPrompt(url: url, code: code)
    }

    static func extractDeviceAuthURL(from text: String) -> URL? {
        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let trailingPunctuation = CharacterSet(charactersIn: ".,;:)]}")

        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let rawURL = String(text[matchRange]).trimmingCharacters(in: trailingPunctuation)
            guard let url = URL(string: rawURL),
                  let host = url.host?.lowercased(),
                  host == "auth.openai.com" || host.hasSuffix(".auth.openai.com") else {
                continue
            }
            return url
        }

        return nil
    }

    static func extractDeviceCode(from text: String) -> String? {
        let pattern = #"\b[A-Z0-9]{4,6}-[A-Z0-9]{4,8}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }
}
