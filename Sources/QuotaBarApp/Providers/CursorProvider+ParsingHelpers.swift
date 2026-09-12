import Foundation

extension CursorProvider {
    func firstDictionary(in object: Any, keys: Set<String>) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let nested = value as? [String: Any] {
                    return nested
                }
                if let nested = firstDictionary(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = firstDictionary(in: value, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    func firstString(in object: Any, keys: Set<String>) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let text = value as? String, !text.isEmpty {
                    return text
                }
                if let nested = firstString(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = firstString(in: value, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    func firstDouble(in object: Any, keys: Set<String>) -> Double? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let number = asDouble(value) {
                    return number
                }
                if let nested = firstDouble(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = firstDouble(in: value, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    func directString(in dict: [String: Any], keys: Set<String>) -> String? {
        for (key, value) in dict where keys.contains(key) {
            if let text = value as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    func directDouble(in dict: [String: Any], keys: Set<String>) -> Double? {
        for (key, value) in dict where keys.contains(key) {
            if let number = asDouble(value) {
                return number
            }
        }
        return nil
    }

    func directDate(in dict: [String: Any], keys: Set<String>) -> Date? {
        for (key, value) in dict where keys.contains(key) {
            if let date = parseDateValue(value) {
                return date
            }
        }
        return nil
    }

    func firstBool(in object: Any, keys: Set<String>) -> Bool? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let bool = asBool(value) {
                    return bool
                }
                if let nested = firstBool(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = firstBool(in: value, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    func firstDate(in object: Any, keys: Set<String>) -> Date? {
        if let raw = firstString(in: object, keys: keys) {
            return parseDate(raw)
        }
        if let raw = firstDouble(in: object, keys: keys) {
            return raw > 2_000_000_000 ? Date(timeIntervalSince1970: raw / 1000) : Date(timeIntervalSince1970: raw)
        }
        return nil
    }

    func asDouble(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Double(trimmed) {
                return number
            }
            let cleaned = trimmed
                .replacingOccurrences(of: "%", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(cleaned)
        }
        return nil
    }

    func asBool(_ value: Any) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func parseDateValue(_ raw: Any) -> Date? {
        if let number = raw as? NSNumber {
            let epoch = number.doubleValue
            return epoch > 2_000_000_000 ? Date(timeIntervalSince1970: epoch / 1000) : Date(timeIntervalSince1970: epoch)
        }
        if let text = raw as? String {
            return parseDate(text)
        }
        return nil
    }

    func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed) {
            return number > 2_000_000_000 ? Date(timeIntervalSince1970: number / 1000) : Date(timeIntervalSince1970: number)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
