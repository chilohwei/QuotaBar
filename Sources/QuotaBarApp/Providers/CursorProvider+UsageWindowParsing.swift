import Foundation

extension CursorProvider {
    func extractCursorUsageWindows(from payload: Any, defaultResetAt: Date?) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        collectCursorUsageWindows(
            from: payload,
            keyHint: nil,
            defaultResetAt: defaultResetAt,
            into: &windows
        )

        var seen = Set<String>()
        return windows.filter { window in
            let reset = window.resetAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "none"
            let key = "\(window.label)-\(window.used)-\(window.limit)-\(reset)"
            return seen.insert(key).inserted
        }
    }

    func collectCursorUsageWindows(
        from node: Any,
        keyHint: String?,
        defaultResetAt: Date?,
        into windows: inout [QuotaWindow]
    ) {
        if let dict = node as? [String: Any] {
            if let window = cursorUsageWindow(from: dict, keyHint: keyHint, defaultResetAt: defaultResetAt) {
                windows.append(window)
            }
            for (key, value) in dict {
                collectCursorUsageWindows(
                    from: value,
                    keyHint: key,
                    defaultResetAt: defaultResetAt,
                    into: &windows
                )
            }
        } else if let array = node as? [Any] {
            for value in array {
                collectCursorUsageWindows(
                    from: value,
                    keyHint: keyHint,
                    defaultResetAt: defaultResetAt,
                    into: &windows
                )
            }
        }
    }

    func cursorUsageWindow(
        from dict: [String: Any],
        keyHint: String?,
        defaultResetAt: Date?
    ) -> QuotaWindow? {
        let label = normalizedCursorWindowLabel(
            directString(in: dict, keys: Self.windowLabelKeys) ?? keyHint
        )
        let resetAt = directDate(in: dict, keys: Self.cycleBoundaryDateKeys) ?? defaultResetAt
        let used = directDouble(in: dict, keys: Self.usedAmountKeys)
        let limit = directDouble(in: dict, keys: Self.limitAmountKeys)
        let remaining = directDouble(in: dict, keys: Self.remainingAmountKeys)

        if let used, let limit, limit > 0 {
            return QuotaWindow(
                label: label,
                used: min(max(used, 0), limit),
                limit: limit,
                resetAt: resetAt
            )
        }

        if let remaining, let limit, limit > 0 {
            return QuotaWindow(
                label: label,
                used: min(max(limit - remaining, 0), limit),
                limit: limit,
                resetAt: resetAt
            )
        }

        if let used, let remaining, used > 0 || remaining > 0 {
            return QuotaWindow(
                label: label,
                used: max(used, 0),
                limit: max(used + remaining, 0),
                resetAt: resetAt
            )
        }

        return parsePercentWindow(
            label: label,
            usedPercent: directDouble(in: dict, keys: Self.percentUsedKeys),
            resetAt: resetAt
        )
    }

    func firstCursorWindow(
        in windows: [QuotaWindow],
        preferredLabels: Set<String>,
        excluding excluded: [QuotaWindow?] = [],
        allowAnyFallback: Bool = true
    ) -> QuotaWindow? {
        let excludedWindows = excluded.compactMap { $0 }
        if let preferred = windows.first(where: { window in
            preferredLabels.contains(window.label) && !excludedWindows.contains(where: { sameCursorWindow($0, window) })
        }) {
            return preferred
        }

        guard allowAnyFallback else { return nil }
        return windows.first { window in
            !excludedWindows.contains(where: { sameCursorWindow($0, window) })
        }
    }

    func sameCursorWindow(_ lhs: QuotaWindow, _ rhs: QuotaWindow) -> Bool {
        lhs.label == rhs.label
            && lhs.used == rhs.used
            && lhs.limit == rhs.limit
            && lhs.resetAt == rhs.resetAt
    }

    func normalizedCursorWindowLabel(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "Usage"
        }

        let normalized = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
        if normalized.contains("api") {
            return "API"
        }
        if normalized.contains("auto") {
            return "Auto"
        }
        if normalized.contains("on demand")
            || normalized.contains("ondemand")
            || normalized.contains("usage based")
            || normalized.contains("hard limit") {
            return "On-demand"
        }
        if normalized.contains("premium")
            || normalized.contains("request")
            || normalized == "num requests" {
            return "Requests"
        }
        if normalized.contains("include") || normalized.contains("plan") {
            return "Included"
        }
        if normalized.contains("total") {
            return "Total"
        }
        if normalized.contains("usage") {
            return "Usage"
        }
        return raw
    }
}
