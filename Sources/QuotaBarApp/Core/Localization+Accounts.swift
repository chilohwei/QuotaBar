import Foundation

extension AppText {
    func addAccountFailedMessage(_ error: String) -> String {
        localized(
            english: "The account was not added. \(error)",
            simplified: "账号还没有添加成功。\(error)",
            traditional: "帳號還沒有新增成功。\(error)"
        )
    }

    func addAccountPhaseText(_ phase: AddAccountPhase) -> String {
        switch phase {
        case .importingLocal:
            return localized(
                english: "Reading local sign-in…",
                simplified: "正在读取本机登录…",
                traditional: "正在讀取本機登入…"
            )
        case .waitingBrowserAuthorization:
            return localized(
                english: "Browser opened — finish authorization there",
                simplified: "已打开浏览器，请完成授权",
                traditional: "已開啟瀏覽器，請完成授權"
            )
        case .fetchingUsage:
            return localized(
                english: "Fetching usage…",
                simplified: "正在获取用量…",
                traditional: "正在獲取用量…"
            )
        }
    }

    func duplicateAccountUpdatedNotice(_ name: String) -> String {
        localized(
            english: "\(name) already exists. Credentials updated.",
            simplified: "\(name) 已存在，凭据已更新。",
            traditional: "\(name) 已存在，憑據已更新。"
        )
    }

    func accountAddedNotice(_ name: String) -> String {
        localized(
            english: "\(name) added.",
            simplified: "已添加 \(name)。",
            traditional: "已新增 \(name)。"
        )
    }

    func addAccountSucceededNotificationTitle(tool: ToolKind) -> String {
        localized(
            english: "\(tool.displayName) account added",
            simplified: "\(tool.displayName) 账号已添加",
            traditional: "\(tool.displayName) 帳號已新增"
        )
    }

    func addAccountFailedNotificationTitle(tool: ToolKind) -> String {
        localized(
            english: "\(tool.displayName) account not added",
            simplified: "\(tool.displayName) 账号添加失败",
            traditional: "\(tool.displayName) 帳號新增失敗"
        )
    }

    func quotaLowNotificationTitle(tool: ToolKind) -> String {
        localized(
            english: "\(tool.displayName) quota is low",
            simplified: "\(tool.displayName) 额度偏低",
            traditional: "\(tool.displayName) 額度偏低"
        )
    }

    func quotaLowNotificationBody(accountName: String, remainingPercent: Int) -> String {
        localized(
            english: "\(accountName) has \(remainingPercent)% remaining.",
            simplified: "\(accountName) 剩余 \(remainingPercent)%。",
            traditional: "\(accountName) 剩餘 \(remainingPercent)%。"
        )
    }

    func quotaExhaustedNotificationTitle(tool: ToolKind) -> String {
        localized(
            english: "\(tool.displayName) quota exhausted",
            simplified: "\(tool.displayName) 额度已用完",
            traditional: "\(tool.displayName) 額度已用完"
        )
    }

    func quotaExhaustedNotificationBody(accountName: String) -> String {
        localized(
            english: "\(accountName) has no quota remaining.",
            simplified: "\(accountName) 的额度已用完。",
            traditional: "\(accountName) 的額度已用完。"
        )
    }

    func quotaRecoveredNotificationTitle(tool: ToolKind) -> String {
        localized(
            english: "\(tool.displayName) quota recovered",
            simplified: "\(tool.displayName) 额度已恢复",
            traditional: "\(tool.displayName) 額度已恢復"
        )
    }

    func quotaRecoveredNotificationBody(accountName: String, remainingPercent: Int) -> String {
        localized(
            english: "\(accountName) is back to \(remainingPercent)% remaining.",
            simplified: "\(accountName) 已恢复，剩余 \(remainingPercent)%。",
            traditional: "\(accountName) 已恢復，剩餘 \(remainingPercent)%。"
        )
    }

    func alertThresholdLabel(_ threshold: Double) -> String {
        "\(Int((threshold * 100).rounded()))%"
    }

    func switchToRecommendedAccount(_ name: String) -> String {
        localized(
            english: "Switch to recommended: \(name)",
            simplified: "切换到推荐账号：\(name)",
            traditional: "切換到推薦帳號：\(name)"
        )
    }

    func switchAccountFailedNotificationTitle(tool: ToolKind) -> String {
        localized(
            english: "\(tool.displayName) account switch failed",
            simplified: "\(tool.displayName) 切换账号失败",
            traditional: "\(tool.displayName) 切換帳號失敗"
        )
    }

    func accountDeletedNotice(_ name: String) -> String {
        localized(
            english: "Deleted \(name).",
            simplified: "已删除 \(name)。",
            traditional: "已刪除 \(name)。"
        )
    }

    func alternativeAccountAvailable(_ name: String) -> String {
        localized(
            english: "Recommended account available: \(name) (switch via right-click menu)",
            simplified: "推荐账号可用：\(name)（右键菜单可切换）",
            traditional: "推薦帳號可用：\(name)（右鍵選單可切換）"
        )
    }

    /// Collapses a full "gist. how-to" error message down to its first sentence for the
    /// compact card footer, where the how-to would just overflow. The full message stays
    /// available on hover (tooltip) and in notifications. Returns the whole string unchanged
    /// when it has no sentence break.
}
