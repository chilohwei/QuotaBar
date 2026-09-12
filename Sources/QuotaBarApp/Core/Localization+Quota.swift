import Foundation

extension AppText {
    func deleteAccountTitle(_ name: String) -> String {
        switch language {
        case .english:
            return "Delete \(name)"
        case .simplifiedChinese:
            return "删除 \(name)"
        case .traditionalChinese:
            return "刪除 \(name)"
        }
    }

    func statusBarTooltip(
        tool: ToolKind,
        remainingPercent: Int,
        accountName: String,
        metadata: String? = nil,
        availability: QuotaAvailabilityStatus? = nil
    ) -> String {
        var parts: [String]
        switch language {
        case .english:
            parts = ["\(tool.displayName) \(accountName) remaining \(remainingPercent)%"]
        case .simplifiedChinese:
            parts = ["\(tool.displayName) \(accountName) 剩余 \(remainingPercent)%"]
        case .traditionalChinese:
            parts = ["\(tool.displayName) \(accountName) 剩餘 \(remainingPercent)%"]
        }
        if let availabilityText = availability.flatMap(quotaAvailabilityText) {
            parts.append(availabilityText)
        }
        if let metadata, !metadata.isEmpty {
            parts.append(metadata)
        }
        return parts.joined(separator: " · ")
    }

    func quotaSnapshotMeta(_ snapshot: QuotaSnapshot) -> String {
        quotaSnapshotMeta(source: snapshot.source, updatedAt: snapshot.updatedAt)
    }

    func quotaSnapshotMeta(source rawSource: String, updatedAt: Date) -> String {
        let source = quotaSourceLabel(rawSource)
        let updated = formatCompactDateTime(updatedAt)
        switch language {
        case .english:
            return "\(source) · updated \(updated)"
        case .simplifiedChinese:
            return "\(source) · 更新于 \(updated)"
        case .traditionalChinese:
            return "\(source) · 更新於 \(updated)"
        }
    }

    func quotaFreshnessBadge(_ snapshot: QuotaSnapshot) -> String? {
        let lowerSource = snapshot.source.lowercased()
        guard !lowerSource.contains("cache") else { return nil }

        let isStale = QuotaFreshness.isStale(snapshot)
        guard isStale else { return nil }

        let time = formatCompactDateTime(snapshot.updatedAt)
        switch language {
        case .english:
            return "Recent \(time)"
        case .simplifiedChinese:
            return "最近 \(time)"
        case .traditionalChinese:
            return "最近 \(time)"
        }
    }

    func quotaAvailabilityText(_ status: QuotaAvailabilityStatus) -> String? {
        switch status {
        case .normal:
            return nil
        case .quotaExhausted:
            return string(.exhausted)
        case .sessionRateLimited:
            return localized(
                english: "Current session is rate-limited",
                simplified: "当前会话受限",
                traditional: "目前會話受限"
            )
        case .authRateLimited:
            return localized(
                english: "Refresh is temporarily slowed",
                simplified: "刷新暂时变慢",
                traditional: "刷新暫時變慢"
            )
        case .serviceUnavailable:
            return localized(
                english: "Live data is temporarily unavailable",
                simplified: "实时数据暂不可用",
                traditional: "即時資料暫不可用"
            )
        }
    }

    func resetAt(_ date: Date?) -> String {
        let time = formatCompactDateTime(date)
        switch language {
        case .english:
            return "Resets \(time)"
        case .simplifiedChinese:
            return "重置 \(time)"
        case .traditionalChinese:
            return "重置 \(time)"
        }
    }

    func recommendationStrategyTitle(_ strategy: AccountRecommendationStrategy) -> String {
        switch language {
        case .english:
            switch strategy {
            case .preventWaste:
                return "Spend first"
            case .maximizeAvailability:
                return "More quota first"
            }
        case .simplifiedChinese:
            switch strategy {
            case .preventWaste:
                return "消耗优先"
            case .maximizeAvailability:
                return "余量优先"
            }
        case .traditionalChinese:
            switch strategy {
            case .preventWaste:
                return "消耗優先"
            case .maximizeAvailability:
                return "餘量優先"
            }
        }
    }

    func recommendationReason(strategy: AccountRecommendationStrategy) -> String {
        switch language {
        case .english:
            switch strategy {
            case .preventWaste:
                return "Spend first"
            case .maximizeAvailability:
                return "More quota first"
            }
        case .simplifiedChinese:
            switch strategy {
            case .preventWaste:
                return "消耗优先"
            case .maximizeAvailability:
                return "余量优先"
            }
        case .traditionalChinese:
            switch strategy {
            case .preventWaste:
                return "消耗優先"
            case .maximizeAvailability:
                return "餘量優先"
            }
        }
    }

    func updatedAt(_ date: Date?) -> String {
        let time = formatCompactDateTime(date)
        switch language {
        case .english:
            return "Updated \(time)"
        case .simplifiedChinese:
            return "更新 \(time)"
        case .traditionalChinese:
            return "更新 \(time)"
        }
    }

    private func quotaSourceLabel(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("cursor") {
            return lower.contains("cache")
                ? (language == .traditionalChinese ? "Cursor 快取" : (language == .english ? "Cursor Cache" : "Cursor 缓存"))
                : "Cursor"
        }
        if lower.contains("claude") {
            if lower.contains("cache") {
                return language == .traditionalChinese ? "Claude Code 快取" : (language == .english ? "Claude Code Cache" : "Claude Code 缓存")
            }
            if lower.contains("oauth") {
                return "Claude Code OAuth"
            }
            return "Claude Code"
        }
        if lower.contains("cache") {
            switch language {
            case .english: return "Cache"
            case .simplifiedChinese: return "缓存"
            case .traditionalChinese: return "快取"
            }
        }
        if lower.contains("oauth") || lower.contains("codex") {
            switch language {
            case .english: return "Codex"
            case .simplifiedChinese: return "Codex 实时"
            case .traditionalChinese: return "Codex 即時"
            }
        }
        if lower.contains("api") {
            return "API"
        }
        return raw
    }

    func quotaLabel(_ raw: String) -> String {
        if raw == "Routines 7d" { return quotaDetailText("Routines weekly", "例行任务·每周", "例行任務·每週") }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "5h", "5 hours", "five hours":
            return language == .english ? "5h" : "5 小时"
        case "weekly", "7d", "7 days", "week":
            return language == .english ? "Weekly" : (language == .traditionalChinese ? "每週" : "每周")
        case "monthly", "month":
            return language == .english ? "Monthly" : (language == .traditionalChinese ? "每月" : "每月")
        case "total":
            return language == .english ? "Total" : (language == .traditionalChinese ? "總量" : "总量")
        case "included", "plan":
            return language == .english ? "Included" : (language == .traditionalChinese ? "包含額度" : "包含额度")
        case "credits", "credit":
            return language == .english ? "Credits" : (language == .traditionalChinese ? "點數" : "点数")
        case "auto":
            return "Auto"
        case "api":
            return "API"
        case "requests":
            return language == .english ? "Requests" : (language == .traditionalChinese ? "請求" : "请求")
        case "on-demand", "on demand", "usage based":
            return language == .english ? "On-demand" : (language == .traditionalChinese ? "按量使用" : "按量使用")
        case "usage":
            return language == .english ? "Usage" : (language == .traditionalChinese ? "用量" : "用量")
        default:
            // Scoped windows like "7d·Fable" (weekly limit for one model family): localize the
            // window part, keep the model name as-is.
            if raw.contains("·") {
                let parts = raw.split(separator: "·", maxSplits: 1).map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, parts[0] != raw {
                    return "\(quotaLabel(parts[0]))·\(parts[1])"
                }
            }
            for suffix in [" 5h", " Weekly", " 7d"] where raw.hasSuffix(suffix) {
                let suffixStart = raw.index(raw.endIndex, offsetBy: -suffix.count)
                let prefix = String(raw[..<suffixStart]).trimmingCharacters(in: .whitespacesAndNewlines)
                let window = String(raw[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    return "\(prefix) \(quotaLabel(window))"
                }
            }
            return raw
        }
    }

    private func formatCompactDateTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = language == .english ? "M/d HH:mm" : "M/d H:mm"
        return formatter.string(from: date)
    }

    private func formatCompactDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    func renewsOn(_ date: Date?) -> String {
        let day = formatCompactDate(date)
        switch language {
        case .english:
            return "Renews \(day)"
        case .simplifiedChinese:
            return "续费 \(day)"
        case .traditionalChinese:
            return "續費 \(day)"
        }
    }

    func expiresOn(_ date: Date?) -> String {
        let day = formatCompactDate(date)
        switch language {
        case .english:
            return "Expires \(day)"
        case .simplifiedChinese:
            return "到期 \(day)"
        case .traditionalChinese:
            return "到期 \(day)"
        }
    }
}
