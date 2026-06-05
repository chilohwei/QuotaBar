import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese:
            return "简体中文"
        case .traditionalChinese:
            return "繁體中文"
        case .english:
            return "English"
        }
    }

    var locale: Locale {
        switch self {
        case .simplifiedChinese:
            return Locale(identifier: "zh_Hans")
        case .traditionalChinese:
            return Locale(identifier: "zh_Hant")
        case .english:
            return Locale(identifier: "en_US")
        }
    }

    private static let storageKey = "QuotaBar.AppLanguage"
    private static let legacyStorageKeys = ["CodeBuddy.AppLanguage", "DevRadar.AppLanguage"]

    static var stored: AppLanguage {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: storageKey)
            ?? legacyStorageKeys.lazy.compactMap { defaults.string(forKey: $0) }.first
        guard let raw, let language = AppLanguage(rawValue: raw) else {
            return .simplifiedChinese
        }
        return language
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

enum BillingCycle {
    case monthly
    case annual
}

enum AppString: String {
    case addAccount
    case addAccountFailedTitle
    case appName
    case cancel
    case cancelAdding
    case checkForUpdates
    case checkingForUpdates
    case current
    case delete
    case deleteLocalOnly
    case deletePromptTitle
    case downloadAndInstall
    case downloadingUpdate
    case emptyAccountsTitle
    case emptyAccountsDescription
    case emptyAvailableAccountsTitle
    case emptyAvailableAccountsDescription
    case error
    case exhausted
    case installingUpdate
    case language
    case launchAtLogin
    case launchAtLoginFailedTitle
    case nearLimit
    case noQuota
    case normal
    case ok
    case pendingRefresh
    case quit
    case refresh
    case refreshing
    case recommended
    case restartRequiredTitle
    case show
    case statusBarNoData
    case staleData
    case upToDateTitle
    case updateAvailableTitle
    case updateCheckFailedTitle
    case verifyingUpdate
    case waitingData
}

struct AppText {
    let language: AppLanguage

    func string(_ key: AppString) -> String {
        switch language {
        case .simplifiedChinese:
            return simplified[key] ?? key.rawValue
        case .traditionalChinese:
            return traditional[key] ?? simplified[key] ?? key.rawValue
        case .english:
            return english[key] ?? key.rawValue
        }
    }

    var usageHeadline: String {
        switch language {
        case .english:
            return "Usage"
        case .simplifiedChinese, .traditionalChinese:
            return "用量"
        }
    }

    func accountFilterAll(count: Int) -> String {
        switch language {
        case .english:
            return "All accounts \(count)"
        case .simplifiedChinese:
            return "所有账号 \(count)"
        case .traditionalChinese:
            return "所有帳號 \(count)"
        }
    }

    func accountFilterAvailable(count: Int) -> String {
        switch language {
        case .english:
            return "Available \(count)"
        case .simplifiedChinese:
            return "可用账号 \(count)"
        case .traditionalChinese:
            return "可用帳號 \(count)"
        }
    }

    func billingCycle(_ cycle: BillingCycle) -> String {
        switch cycle {
        case .monthly:
            return language == .english ? "Monthly" : (language == .traditionalChinese ? "月度" : "月度")
        case .annual:
            return language == .english ? "Annual" : (language == .traditionalChinese ? "年度" : "年度")
        }
    }

    func restartRequiredMessage(accountName: String) -> String {
        switch language {
        case .english:
            return "Switched to \(accountName). Restart the app to apply this account."
        case .simplifiedChinese:
            return "已切换到 \(accountName)。请重启应用后生效。"
        case .traditionalChinese:
            return "已切換到 \(accountName)。請重啟應用後生效。"
        }
    }

    func updateAvailableMessage(version: String, currentVersion: String) -> String {
        switch language {
        case .english:
            return "QuotaBar \(version) is available. Current version: \(currentVersion). Download, install, and restart now?"
        case .simplifiedChinese:
            return "发现 QuotaBar \(version)。当前版本：\(currentVersion)。是否立即下载、安装并重启？"
        case .traditionalChinese:
            return "發現 QuotaBar \(version)。目前版本：\(currentVersion)。是否立即下載、安裝並重啟？"
        }
    }

    func upToDateMessage(currentVersion: String, latestVersion: String) -> String {
        switch language {
        case .english:
            return "QuotaBar is up to date. Current version: \(currentVersion). Latest release: \(latestVersion)."
        case .simplifiedChinese:
            return "QuotaBar 已是最新版本。当前版本：\(currentVersion)，最新发布：\(latestVersion)。"
        case .traditionalChinese:
            return "QuotaBar 已是最新版本。目前版本：\(currentVersion)，最新發布：\(latestVersion)。"
        }
    }

    func updateCheckFailedMessage(_ error: String) -> String {
        switch language {
        case .english:
            return "Could not check GitHub Releases: \(error)"
        case .simplifiedChinese:
            return "无法检查 GitHub Releases：\(error)"
        case .traditionalChinese:
            return "無法檢查 GitHub Releases：\(error)"
        }
    }

    func launchAtLoginFailedMessage(_ error: String) -> String {
        switch language {
        case .english:
            return "Could not update the login item: \(error)"
        case .simplifiedChinese:
            return "无法更新开机自启设置：\(error)"
        case .traditionalChinese:
            return "無法更新開機自啟設定：\(error)"
        }
    }

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

    func statusBarTooltip(tool: ToolKind, remainingPercent: Int) -> String {
        switch language {
        case .english:
            return "\(tool.displayName) remaining \(remainingPercent)%"
        case .simplifiedChinese:
            return "\(tool.displayName) 剩余 \(remainingPercent)%"
        case .traditionalChinese:
            return "\(tool.displayName) 剩餘 \(remainingPercent)%"
        }
    }

    func quotaSnapshotMeta(_ snapshot: QuotaSnapshot) -> String {
        let source = quotaSourceLabel(snapshot.source)
        let updated = formatCompactDateTime(snapshot.updatedAt)
        switch language {
        case .english:
            return "\(source) · updated \(updated)"
        case .simplifiedChinese:
            return "\(source) · 更新于 \(updated)"
        case .traditionalChinese:
            return "\(source) · 更新於 \(updated)"
        }
    }

    func staleQuotaMessage(_ error: String) -> String {
        switch language {
        case .english:
            return "Refresh failed, showing last data: \(error)"
        case .simplifiedChinese:
            return "刷新失败，正在显示上次数据：\(error)"
        case .traditionalChinese:
            return "刷新失敗，正在顯示上次資料：\(error)"
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
            return lower.contains("cache")
                ? (language == .traditionalChinese ? "Claude Code 快取" : (language == .english ? "Claude Code Cache" : "Claude Code 缓存"))
                : "Claude Code"
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
        case "usage":
            return language == .english ? "Usage" : (language == .traditionalChinese ? "用量" : "用量")
        default:
            return raw
        }
    }

    func formatCompactDateTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = language == .english ? "M/d HH:mm" : "M/d H:mm"
        return formatter.string(from: date)
    }

    func formatCompactDate(_ date: Date?) -> String {
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

    func cycleEndsOn(_ date: Date?) -> String {
        let day = formatCompactDate(date)
        switch language {
        case .english:
            return "Cycle \(day)"
        case .simplifiedChinese:
            return "周期 \(day)"
        case .traditionalChinese:
            return "週期 \(day)"
        }
    }

    private var simplified: [AppString: String] {
        [
            .addAccount: "添加",
            .addAccountFailedTitle: "添加账号失败",
            .appName: "QuotaBar",
            .cancel: "取消",
            .cancelAdding: "取消",
            .checkForUpdates: "检查更新",
            .checkingForUpdates: "正在检查更新...",
            .current: "当前使用",
            .delete: "删除",
            .deleteLocalOnly: "仅删除本地记录，不影响线上账号。",
            .deletePromptTitle: "删除账号？",
            .emptyAccountsTitle: "暂无账号",
            .emptyAccountsDescription: "可读取本机登录状态，也可添加账号。",
            .emptyAvailableAccountsTitle: "当前筛选无账号",
            .emptyAvailableAccountsDescription: "切换到全部账号查看等待同步、无额度或错误状态的账号。",
            .error: "错误",
            .exhausted: "不可用",
            .installingUpdate: "正在安装更新...",
            .language: "语言",
            .launchAtLogin: "开机自启",
            .launchAtLoginFailedTitle: "开机自启设置失败",
            .nearLimit: "偏低",
            .noQuota: "无额度",
            .normal: "正常",
            .ok: "知道了",
            .downloadAndInstall: "下载并安装",
            .downloadingUpdate: "正在下载更新...",
            .pendingRefresh: "待刷新",
            .quit: "退出",
            .refresh: "刷新",
            .refreshing: "刷新中",
            .recommended: "推荐",
            .restartRequiredTitle: "重启后生效",
            .show: "显示",
            .statusBarNoData: "QuotaBar",
            .staleData: "旧数据",
            .upToDateTitle: "已是最新版本",
            .updateAvailableTitle: "发现新版本",
            .updateCheckFailedTitle: "检查更新失败",
            .verifyingUpdate: "正在校验安装包...",
            .waitingData: "暂无数据"
        ]
    }

    private var traditional: [AppString: String] {
        [
            .addAccount: "新增",
            .addAccountFailedTitle: "新增帳號失敗",
            .appName: "QuotaBar",
            .cancel: "取消",
            .cancelAdding: "取消新增",
            .checkForUpdates: "檢查更新",
            .checkingForUpdates: "正在檢查更新...",
            .current: "目前使用",
            .delete: "刪除",
            .deleteLocalOnly: "僅刪除本機記錄，不影響線上帳號。",
            .deletePromptTitle: "刪除帳號？",
            .emptyAccountsTitle: "暫無帳號",
            .emptyAccountsDescription: "可讀取本機登入狀態，也可新增帳號。",
            .emptyAvailableAccountsTitle: "目前篩選無帳號",
            .emptyAvailableAccountsDescription: "切換到全部帳號查看等待同步、無額度或錯誤狀態的帳號。",
            .error: "錯誤",
            .exhausted: "不可用",
            .installingUpdate: "正在安裝更新...",
            .language: "語言",
            .launchAtLogin: "開機自啟",
            .launchAtLoginFailedTitle: "開機自啟設定失敗",
            .nearLimit: "偏低",
            .noQuota: "無額度",
            .normal: "正常",
            .ok: "知道了",
            .downloadAndInstall: "下載並安裝",
            .downloadingUpdate: "正在下載更新...",
            .pendingRefresh: "待刷新",
            .quit: "退出",
            .refresh: "刷新",
            .refreshing: "刷新中",
            .recommended: "推薦",
            .restartRequiredTitle: "重啟後生效",
            .show: "顯示",
            .statusBarNoData: "QuotaBar",
            .staleData: "舊資料",
            .upToDateTitle: "已是最新版本",
            .updateAvailableTitle: "發現新版本",
            .updateCheckFailedTitle: "檢查更新失敗",
            .verifyingUpdate: "正在校驗安裝包...",
            .waitingData: "暫無資料"
        ]
    }

    private var english: [AppString: String] {
        [
            .addAccount: "Add",
            .addAccountFailedTitle: "Add account failed",
            .appName: "QuotaBar",
            .cancel: "Cancel",
            .cancelAdding: "Cancel",
            .checkForUpdates: "Check for Updates",
            .checkingForUpdates: "Checking for updates...",
            .current: "Active",
            .delete: "Delete",
            .deleteLocalOnly: "Removes local data only. Online access is unchanged.",
            .deletePromptTitle: "Delete account?",
            .emptyAccountsTitle: "No accounts yet",
            .emptyAccountsDescription: "Use local sign-in or add an account.",
            .emptyAvailableAccountsTitle: "No accounts in this filter",
            .emptyAvailableAccountsDescription: "Switch to All to view accounts waiting for sync, out of quota, or in an error state.",
            .error: "Error",
            .exhausted: "Unavailable",
            .installingUpdate: "Installing update...",
            .language: "Language",
            .launchAtLogin: "Launch at Login",
            .launchAtLoginFailedTitle: "Launch at Login Failed",
            .nearLimit: "Low",
            .noQuota: "No quota",
            .normal: "OK",
            .ok: "OK",
            .downloadAndInstall: "Download and Install",
            .downloadingUpdate: "Downloading update...",
            .pendingRefresh: "Pending",
            .quit: "Quit",
            .refresh: "Refresh",
            .refreshing: "Refreshing",
            .recommended: "Recommended",
            .restartRequiredTitle: "Restart required",
            .show: "Show",
            .statusBarNoData: "QuotaBar",
            .staleData: "Stale",
            .upToDateTitle: "Up to Date",
            .updateAvailableTitle: "Update Available",
            .updateCheckFailedTitle: "Update Check Failed",
            .verifyingUpdate: "Verifying update...",
            .waitingData: "No data"
        ]
    }
}
