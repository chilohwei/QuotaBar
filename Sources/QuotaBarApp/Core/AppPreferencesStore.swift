import Foundation

enum AppPreferencesStore {
    private static let refreshOnOpenKey = "QuotaBar.RefreshOnOpenEnabled"
    private static let recommendationStrategyKey = "QuotaBar.RecommendationStrategy"
    private static let menuBarVisibleToolsKey = "QuotaBar.MenuBarVisibleTools"
    private static let ignoredUpdateVersionKey = "QuotaBar.IgnoredUpdateVersion"

    static var refreshOnOpenEnabled: Bool {
        bool(forKey: refreshOnOpenKey, defaultValue: true)
    }

    static var menuBarVisibleTools: Set<ToolKind> {
        // Absent key (first launch) means show everything; an explicitly empty
        // saved array is honored as "show none".
        guard let raw = UserDefaults.standard.array(forKey: menuBarVisibleToolsKey) as? [String] else {
            return Set(ToolKind.allCases)
        }
        return Set(raw.compactMap(ToolKind.init(rawValue:)))
    }

    static func setMenuBarVisibleTools(_ tools: Set<ToolKind>) {
        UserDefaults.standard.set(tools.map(\.rawValue), forKey: menuBarVisibleToolsKey)
    }

    static var recommendationStrategy: AccountRecommendationStrategy {
        guard let rawValue = UserDefaults.standard.string(forKey: recommendationStrategyKey),
              let strategy = AccountRecommendationStrategy(rawValue: rawValue) else {
            return .preventWaste
        }
        return strategy
    }

    static var ignoredUpdateVersion: String? {
        UserDefaults.standard.string(forKey: ignoredUpdateVersionKey)
    }

    static func isUpdateVersionIgnored(_ version: String) -> Bool {
        ignoredUpdateVersion == version
    }

    static func setRefreshOnOpenEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: refreshOnOpenKey)
    }

    static func setRecommendationStrategy(_ strategy: AccountRecommendationStrategy) {
        UserDefaults.standard.set(strategy.rawValue, forKey: recommendationStrategyKey)
    }

    static func setIgnoredUpdateVersion(_ version: String?) {
        if let version {
            UserDefaults.standard.set(version, forKey: ignoredUpdateVersionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ignoredUpdateVersionKey)
        }
    }

    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}
