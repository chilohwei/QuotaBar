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
    case cancel
    case cancelAdding
    case checkForUpdates
    case checkingForUpdates
    case current
    case currentBadge
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
    case ignore
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
    case refreshOnOpen
    case refreshing
    case recommended
    case recommendedReason
    case recommendationStrategy
    case remaining
    case settings
    case settingsApp
    case settingsMenuBar
    case settingsNotifications
    case quotaAlerts
    case alertThreshold
    case menuBarToolsHint
    case settingsRefresh
    case show
    case statusBarNoData
    case staleData
    case switchAccount
    case reopenAuthPage
    case undo
    case restartNow
    case restartRequiredTitle
    case later
    case upToDateTitle
    case updateAvailableTitle
    case updateCheckFailedTitle
    case update
    case updated
    case verifyingUpdate
    case waitingData
    case useAccount
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

    func localized(english: String, simplified: String, traditional: String) -> String {
        switch language {
        case .english:
            return english
        case .simplifiedChinese:
            return simplified
        case .traditionalChinese:
            return traditional
        }
    }
}
