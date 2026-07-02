import Foundation

extension ClaudeCodeProvider {
    func parseJSONObject(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    func firstValue(in dict: [String: Any], keys: Set<String>) -> Any? {
        for (key, value) in dict where keys.contains(key) {
            return value
        }
        return nil
    }

    func firstDictionary(in dict: [String: Any], keys: Set<String>) -> [String: Any]? {
        for (key, value) in dict where keys.contains(key) {
            if let value = value as? [String: Any] {
                return value
            }
        }
        return nil
    }

    func firstString(in object: Any, keys: Set<String>) -> String? {
        findString(in: object, keys: keys)
    }

    func findString(in object: Any, keys: Set<String>) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let text = string(value), !text.isEmpty {
                    return text
                }
                if let text = findString(in: value, keys: keys) {
                    return text
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let text = findString(in: value, keys: keys) {
                    return text
                }
            }
        }
        return nil
    }

    func findValue(in object: Any, keys: Set<String>) -> Any? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key) {
                    return value
                }
                if let found = findValue(in: value, keys: keys) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findValue(in: value, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    func collectStrings(in object: Any, into strings: inout [String]) {
        guard strings.count < 200 else { return }
        if let text = object as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                strings.append(String(trimmed.prefix(2_000)))
            }
        } else if let dict = object as? [String: Any] {
            for value in dict.values {
                collectStrings(in: value, into: &strings)
                if strings.count >= 200 { break }
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectStrings(in: value, into: &strings)
                if strings.count >= 200 { break }
            }
        }
    }

    func parseRateLimitResetDate(in text: String, referenceDate: Date) -> Date? {
        let pattern = #"(?i)\breset(?:s)?(?:\s+at)?\s+([0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)?)(?:\s*\(([A-Za-z_]+/[A-Za-z_]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let timeRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let timeZone: TimeZone
        if match.numberOfRanges > 2,
           let zoneRange = Range(match.range(at: 2), in: text),
           let parsed = TimeZone(identifier: String(text[zoneRange])) {
            timeZone = parsed
        } else {
            timeZone = .current
        }

        return parseResetTimeOfDay(
            String(text[timeRange]),
            timeZone: timeZone,
            referenceDate: referenceDate
        )
    }

    func parseResetTimeOfDay(
        _ raw: String,
        timeZone: TimeZone,
        referenceDate: Date
    ) -> Date? {
        if let directDate = parseFlexibleDate(raw) {
            return directDate
        }

        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false
        let formats = ["H:mm", "HH:mm", "H", "h:mma", "ha"]

        for format in formats {
            formatter.dateFormat = format
            guard let parsedTime = formatter.date(from: normalized) else { continue }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let timeComponents = calendar.dateComponents([.hour, .minute], from: parsedTime)
            var resetComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            resetComponents.hour = timeComponents.hour
            resetComponents.minute = timeComponents.minute ?? 0
            resetComponents.second = 0

            guard var resetAt = calendar.date(from: resetComponents) else { continue }
            if resetAt.addingTimeInterval(60) < referenceDate,
               let nextDay = calendar.date(byAdding: .day, value: 1, to: resetAt) {
                resetAt = nextDay
            }
            return resetAt
        }

        return nil
    }

    func parseFlexibleDate(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber {
            return dateFromEpochOrSeconds(number.doubleValue)
        }
        if let double = raw as? Double {
            return dateFromEpochOrSeconds(double)
        }
        if let int = raw as? Int {
            return dateFromEpochOrSeconds(Double(int))
        }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let epoch = Double(trimmed) {
                return dateFromEpochOrSeconds(epoch)
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

    func dateFromEpochOrSeconds(_ raw: Double) -> Date {
        raw > 2_000_000_000
            ? Date(timeIntervalSince1970: raw / 1000)
            : Date(timeIntervalSince1970: raw)
    }

    func string(_ value: Any) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
