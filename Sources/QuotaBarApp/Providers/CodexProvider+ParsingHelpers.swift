import Foundation

extension String {
    func strippingANSIControlSequences() -> String {
        let escape = "\u{001B}"
        return replacingOccurrences(
            of: "\(escape)\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    func singleLineCondensed(maxLength: Int) -> String {
        let condensed = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard condensed.count > maxLength else { return condensed }
        return "\(condensed.prefix(maxLength))..."
    }

    func upsertingTopLevelTOMLString(key: String, value: String) -> String {
        let assignment = "\(key) = \"\(value)\""
        var lines = split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var firstTableIndex: Int?
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                firstTableIndex = index
                break
            }
            guard trimmed.isEmpty == false,
                  trimmed.hasPrefix("#") == false else {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key {
                lines[index] = assignment
                return lines.joined(separator: "\n").ensuringTrailingNewline()
            }
        }

        if lines.isEmpty {
            return "\(assignment)\n"
        }

        if let firstTableIndex {
            lines.insert(assignment, at: firstTableIndex)
            if firstTableIndex + 1 < lines.count,
               lines[firstTableIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                lines.insert("", at: firstTableIndex + 1)
            }
            return lines.joined(separator: "\n").ensuringTrailingNewline()
        }

        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("")
        }
        lines.append(assignment)
        return lines.joined(separator: "\n").ensuringTrailingNewline()
    }

    func ensuringTrailingNewline() -> String {
        hasSuffix("\n") ? self : "\(self)\n"
    }

    func flatMapChatGPTBaseURL() -> String? {
        for rawLine in split(whereSeparator: \.isNewline) {
            let uncommented = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
            let trimmed = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url" else { continue }

            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }

        return nil
    }
}

enum JSONObjectPath {
    static func findString(in object: Any, keys: Set<String>) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let text = asString(value) {
                    return text
                }
                if let nested = findString(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let text = findString(in: item, keys: keys) {
                    return text
                }
            }
        }
        return nil
    }

    static func findDouble(in object: Any, keys: Set<String>) -> Double? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let number = asDouble(value) {
                    return number
                }
                if let nested = findDouble(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let number = findDouble(in: item, keys: keys) {
                    return number
                }
            }
        }
        return nil
    }

    static func findBool(in object: Any, keys: Set<String>) -> Bool? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let bool = asBool(value) {
                    return bool
                }
                if let nested = findBool(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let bool = findBool(in: item, keys: keys) {
                    return bool
                }
            }
        }
        return nil
    }

    static func asString(_ value: Any) -> String? {
        if let text = value as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    static func asBool(_ value: Any) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    static func asDouble(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

enum UsageWindowExtractor {
    static func extract(from payload: Any) -> [QuotaWindow] {
        var results: [QuotaWindow] = []
        walk(payload, keyHint: nil, collector: &results)

        var seen = Set<String>()
        return results.filter { window in
            let key = "\(window.label)-\(window.limit)-\(window.used)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    static func walk(_ node: Any, keyHint: String?, collector: inout [QuotaWindow]) {
        if let dict = node as? [String: Any] {
            if let window = parseWindow(from: dict, keyHint: keyHint) {
                collector.append(window)
            }
            for (key, value) in dict {
                walk(value, keyHint: key, collector: &collector)
            }
        } else if let array = node as? [Any] {
            for value in array {
                walk(value, keyHint: keyHint, collector: &collector)
            }
        }
    }

    static func parseWindow(from dict: [String: Any], keyHint: String?) -> QuotaWindow? {
        let used = firstDouble(in: dict, keys: ["used", "usage", "used_amount", "consumed", "spent", "used_usd", "value_used"])
        let remaining = firstDouble(in: dict, keys: ["remaining", "left", "available", "remaining_amount", "value_remaining"])
        let limit = firstDouble(in: dict, keys: ["limit", "max", "quota", "total", "capacity", "value_limit"])

        let resolvedLimit: Double
        let resolvedUsed: Double

        if let limit, let used {
            resolvedLimit = limit
            resolvedUsed = used
        } else if let limit, let remaining {
            resolvedLimit = limit
            resolvedUsed = max(limit - remaining, 0)
        } else if let used, let remaining {
            resolvedLimit = used + remaining
            resolvedUsed = used
        } else {
            return nil
        }

        guard resolvedLimit > 0 else {
            return nil
        }

        let label = normalizedLabel(from: keyHint)
        let resetAt = parseDate(value: firstValue(in: dict, keys: ["reset_at", "resets_at", "resetAt", "next_reset_at", "end_at", "ends_at"]))

        return QuotaWindow(
            label: label,
            used: resolvedUsed,
            limit: resolvedLimit,
            resetAt: resetAt
        )
    }

    static func normalizedLabel(from keyHint: String?) -> String {
        guard let hint = keyHint?.lowercased() else {
            return "Usage"
        }

        if hint.contains("five") || hint.contains("5h") {
            return "5h"
        }
        if hint.contains("week") || hint.contains("seven") {
            return "Weekly"
        }
        if hint.contains("month") {
            return "Monthly"
        }
        return keyHint ?? "Usage"
    }

    static func firstDouble(in dict: [String: Any], keys: Set<String>) -> Double? {
        for (key, value) in dict where keys.contains(key) {
            if let number = asDouble(value) {
                return number
            }
        }
        return nil
    }

    static func firstValue(in dict: [String: Any], keys: Set<String>) -> Any? {
        for (key, value) in dict where keys.contains(key) {
            return value
        }
        return nil
    }

    static func asDouble(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func parseDate(value: Any?) -> Date? {
        guard let value else { return nil }

        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return raw > 2_000_000_000 ? Date(timeIntervalSince1970: raw / 1000) : Date(timeIntervalSince1970: raw)
        }

        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) {
                return date
            }
            if let raw = Double(text) {
                return raw > 2_000_000_000 ? Date(timeIntervalSince1970: raw / 1000) : Date(timeIntervalSince1970: raw)
            }
        }

        return nil
    }
}
