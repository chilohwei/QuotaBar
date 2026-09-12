import Foundation

extension AppText {
    var spendLimitUnknown: String { quotaDetailText("Spending limit not provided", "未提供消费上限", "未提供消費上限") }
    func spendLabel(_ label: String) -> String {
        switch label {
        case "Included": return quotaDetailText("Included spend", "套餐内已消费", "方案內已消費")
        case "On-demand": return quotaDetailText("On-demand spend", "按量已消费", "按量已消費")
        default: return quotaDetailText("Extra usage spend", "额外用量已消费", "額外用量已消費")
        }
    }
    func spendLimit(_ limit: Double, currency: String) -> String {
        let amount = limit.formatted(.currency(code: currency))
        return quotaDetailText("Spending limit \(amount)", "消费上限 \(amount)", "消費上限 \(amount)")
    }

    var resetCreditsTitle: String { quotaDetailText("Quota resets", "额度重置", "額度重置") }
    var resetCreditsUnknown: String { quotaDetailText("Resets unknown", "重置次数未知", "重置次數未知") }
    var resetCreditsUnavailable: String { quotaDetailText("Reset inventory unavailable. Refresh to retry.", "未能获取重置次数，请刷新重试。", "未能取得重置次數，請重新整理重試。") }
    var expiryUnknown: String { quotaDetailText("Expiry not provided", "未提供到期时间", "未提供到期時間") }
    func resetCreditsCount(_ count: Int) -> String {
        quotaDetailText("\(count) reset\(count == 1 ? "" : "s")", "可重置 \(count) 次", "可重置 \(count) 次")
    }
    func creditExpiry(_ date: Date) -> String {
        quotaDetailText("Expires \(exactReset(date))", "到期 \(exactReset(date))", "到期 \(exactReset(date))")
    }

    var accountActionsTitle: String {
        quotaDetailText("Account actions", "账号操作", "帳號操作")
    }

    var otherQuotaTitle: String {
        quotaDetailText("More quotas", "更多额度", "更多額度")
    }

    var resetUnavailable: String {
        quotaDetailText("Reset time unavailable", "未提供重置时间", "未提供重置時間")
    }

    func resetCountdown(_ resetAt: Date, now: Date) -> String {
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else {
            return quotaDetailText("Reset awaiting confirmation", "等待确认重置", "等待確認重置")
        }
        let minutes = max(1, Int(ceil(seconds / 60)))
        let duration: String
        if minutes >= 1440 {
            duration = quotaDetailText("\(minutes / 1440)d \((minutes % 1440) / 60)h", "\(minutes / 1440)天 \((minutes % 1440) / 60)小时", "\(minutes / 1440)天 \((minutes % 1440) / 60)小時")
        } else if minutes >= 60 {
            duration = quotaDetailText("\(minutes / 60)h \(minutes % 60)m", "\(minutes / 60)小时 \(minutes % 60)分", "\(minutes / 60)小時 \(minutes % 60)分")
        } else {
            duration = quotaDetailText("\(minutes)m", "\(minutes)分钟", "\(minutes)分鐘")
        }
        let compactDuration = duration
            .replacingOccurrences(of: " 0h", with: "")
            .replacingOccurrences(of: " 0m", with: "")
            .replacingOccurrences(of: " 0小时", with: "")
            .replacingOccurrences(of: " 0小時", with: "")
            .replacingOccurrences(of: " 0分", with: "")
        return quotaDetailText("Resets in \(compactDuration)", "\(compactDuration) 后重置", "\(compactDuration) 後重置")
    }

    func exactReset(_ resetAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .english ? "en_US" : "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm z"
        return formatter.string(from: resetAt)
    }

    func quotaDetailText(_ english: String, _ simplified: String, _ traditional: String) -> String {
        localized(english: english, simplified: simplified, traditional: traditional)
    }
}
