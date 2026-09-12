import Foundation

extension CodexProvider {
    func parseLastRefresh(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    func accessTokenExpiresSoon(_ token: String) -> Bool {
        guard let expiresAt = jwtExpirationDate(token) else { return false }
        return expiresAt <= Date().addingTimeInterval(tokenRefreshLeeway)
    }

    func jwtExpirationDate(_ token: String?) -> Date? {
        guard let exp = parseJWT(token)?["exp"] else { return nil }
        if let number = exp as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let double = exp as? Double {
            return Date(timeIntervalSince1970: double)
        }
        if let int = exp as? Int {
            return Date(timeIntervalSince1970: TimeInterval(int))
        }
        if let text = exp as? String, let double = Double(text) {
            return Date(timeIntervalSince1970: double)
        }
        return nil
    }

    func findDate(in object: Any, keys: Set<String>) -> Date? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let date = parseFlexibleDate(value) {
                    return date
                }
                if let nested = findDate(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let date = findDate(in: item, keys: keys) {
                    return date
                }
            }
        }
        return nil
    }

    func parseFlexibleDate(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber {
            let epoch = number.doubleValue
            return epoch > 2_000_000_000
                ? Date(timeIntervalSince1970: epoch / 1000)
                : Date(timeIntervalSince1970: epoch)
        }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let epoch = Double(trimmed) {
                return epoch > 2_000_000_000
                    ? Date(timeIntervalSince1970: epoch / 1000)
                    : Date(timeIntervalSince1970: epoch)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: trimmed) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: trimmed)
        }
        return nil
    }

    func stringValue(in dictionary: [String: Any]?, snakeKey: String, camelKey: String) -> String? {
        guard let dictionary else { return nil }
        if let value = dictionary[snakeKey] as? String, !value.isEmpty {
            return value
        }
        if let value = dictionary[camelKey] as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    func extractErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let code = error["code"] as? String {
            return code
        }
        if let error = json["error"] as? String {
            return error
        }
        return json["code"] as? String
    }
}
