import Foundation

/// Canonical status-note strings emitted by the providers.
///
/// A provider records exactly one of these (or a composed/data string) on `QuotaSnapshot.note`, and
/// that canonical value is what gets cached to disk. The UI turns it into the user's language at
/// render time via `AppText.localizedNote(_:)`, so switching language re-localizes cached notes and
/// no localized text is ever frozen into the cache. Simplified Chinese is the canonical/base form,
/// mirroring how `AppText.string` falls back (`traditional ?? simplified`).
///
/// Wording is written for the user, not the implementation: it says what the reading means for them
/// and what (if anything) to do — never internal terms like "接口 / 快照 / statusLine / 字段".
enum QuotaNoteCatalog {
    // MARK: Claude Code
    static func claudeStaleLiveData(minutes: Int) -> String {
        "显示约 \(minutes) 分钟前的额度，稍后会自动更新。"
    }
    static let claudeStaleLiveDataPrefix = "显示约 "
    private static let legacyClaudeStaleLiveDataPrefix = "暂时无法刷新，显示的是约 "
    static let claudeRateLimitReached =
        "本轮额度已用完，需等到重置时间后自动恢复。"
    static let claudeUsageRateLimited =
        "Claude 暂时放慢了刷新频率，QuotaBar 会稍后自动重试。"
    static let claudeAwaitingSession =
        "还没有额度数据，在 Claude Code 里用一次后即可显示。"
    static let claudeCredentialsAwaitingClaudeCode =
        "登录凭据自动续期中，稍后会自动恢复实时数据。"
    static let claudeWindowStale =
        "显示最近一次可用额度，稍后会自动更新。"
    static let claudeApiKeyNoWindows =
        "当前为 API Key / 第三方模式，没有 5 小时 / 每周额度限制。"
    static let claudeStatusLineNoWindows =
        "额度数据同步中，在 Claude Code 里用一次后会显示。"

    // MARK: Cursor
    static let cursorLiveUnavailableCache = "显示最近一次额度，稍后会自动更新。"
    static let cursorLegacyNoStandardFields = "未能读取到额度数据，可能是该账号类型暂不支持。"

    // MARK: Codex
    static let codexEmptyQuotaFields = "暂时没有额度数据。"
    static let codexOAuthFellBackToApiKey = "正在使用 API Key 显示额度。"
    static let codexLiveUnavailableCache = "显示最近一次 Codex 额度，稍后会自动更新。"
    static let codexNoStandardFields = "未能识别到额度数据。"

    /// Extracts the minute count from a canonical stale-live-data note, if that is what `raw` is.
    static func staleLiveDataMinutes(from raw: String) -> Int? {
        for prefix in [claudeStaleLiveDataPrefix, legacyClaudeStaleLiveDataPrefix] where raw.hasPrefix(prefix) {
            let digits = raw.dropFirst(prefix.count).prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }
}

extension AppText {
    /// Resolves a canonical provider note (see `QuotaNoteCatalog`) into the current language.
    /// Unknown or composed notes (e.g. Cursor's "Included $8/$20 · On-demand $3", which is already
    /// language-neutral) pass through unchanged.
    func localizedNote(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let minutes = QuotaNoteCatalog.staleLiveDataMinutes(from: raw) {
            return claudeStaleLiveDataText(minutes: minutes)
        }
        switch raw {
        case QuotaNoteCatalog.claudeRateLimitReached:
            switch language {
            case .english:
                return "You’ve used up this window’s quota. It comes back at the reset time."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "本輪額度已用完，需等到重置時間後自動恢復。"
            }
        case QuotaNoteCatalog.claudeUsageRateLimited:
            switch language {
            case .english:
                return "Claude is slowing refreshes for a bit. QuotaBar will try again automatically."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "Claude 暫時放慢了刷新頻率，QuotaBar 會稍後自動重試。"
            }
        case QuotaNoteCatalog.claudeAwaitingSession:
            switch language {
            case .english:
                return "No usage data yet — use Claude Code once and it’ll show up here."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "還沒有額度資料，在 Claude Code 裡用一次後即可顯示。"
            }
        case QuotaNoteCatalog.claudeCredentialsAwaitingClaudeCode:
            switch language {
            case .english:
                return "Renewing Claude Code's sign-in automatically — live data resumes shortly."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "登入憑據自動續期中，稍後會自動恢復即時資料。"
            }
        case QuotaNoteCatalog.claudeWindowStale:
            switch language {
            case .english:
                return "Showing the most recent available quota. It will update automatically."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "顯示最近一次可用額度，稍後會自動更新。"
            }
        case QuotaNoteCatalog.claudeApiKeyNoWindows:
            switch language {
            case .english:
                return "API key / third-party mode has no 5-hour or weekly limits to show."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "目前為 API Key / 第三方模式，沒有 5 小時 / 每週額度限制。"
            }
        case QuotaNoteCatalog.claudeStatusLineNoWindows:
            switch language {
            case .english:
                return "Syncing usage — it’ll appear after your next Claude Code response."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "額度資料同步中，在 Claude Code 裡用一次後會顯示。"
            }
        case QuotaNoteCatalog.cursorLiveUnavailableCache:
            switch language {
            case .english:
                return "Showing your most recent quota. It will update automatically."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "顯示最近一次額度，稍後會自動更新。"
            }
        case QuotaNoteCatalog.cursorLegacyNoStandardFields:
            switch language {
            case .english:
                return "Couldn’t read quota data — this account type may not be supported."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "未能讀取到額度資料，可能是該帳號類型暫不支援。"
            }
        case QuotaNoteCatalog.codexEmptyQuotaFields:
            switch language {
            case .english:
                return "No quota data available right now."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "暫時沒有額度資料。"
            }
        case QuotaNoteCatalog.codexOAuthFellBackToApiKey:
            switch language {
            case .english:
                return "Using your API key to show quota."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "正在使用 API Key 顯示額度。"
            }
        case QuotaNoteCatalog.codexLiveUnavailableCache:
            switch language {
            case .english:
                return "Showing your most recent Codex quota. It will update automatically."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "顯示最近一次 Codex 額度，稍後會自動更新。"
            }
        case QuotaNoteCatalog.codexNoStandardFields:
            switch language {
            case .english:
                return "Couldn’t recognize any quota data."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "未能辨識到額度資料。"
            }
        default:
            return raw
        }
    }

    /// Non-actionable freshness notes should not occupy card space. The cached quota remains useful,
    /// and AppState revalidates it in the background on open/focus/reconnect.
    func shouldDisplayNoteOnCard(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        if QuotaNoteCatalog.staleLiveDataMinutes(from: raw) != nil {
            return false
        }
        switch raw {
        case QuotaNoteCatalog.claudeRateLimitReached,
             QuotaNoteCatalog.claudeUsageRateLimited,
             QuotaNoteCatalog.claudeWindowStale,
             QuotaNoteCatalog.cursorLiveUnavailableCache,
             QuotaNoteCatalog.codexLiveUnavailableCache,
             QuotaNoteCatalog.codexOAuthFellBackToApiKey:
            return false
        default:
            return true
        }
    }

    private func claudeStaleLiveDataText(minutes: Int) -> String {
        let age = Self.humanizedAge(minutes: minutes, language: language)
        switch language {
        case .english:
            return "Showing quota from about \(age) ago. It will update automatically."
        case .simplifiedChinese:
            return "显示约 \(age)前的额度，稍后会自动更新。"
        case .traditionalChinese:
            return "顯示約 \(age)前的額度，稍後會自動更新。"
        }
    }

    /// "480 分钟" reads poorly — convert to hours/days once past an hour.
    static func humanizedAge(minutes: Int, language: AppLanguage) -> String {
        if minutes >= 24 * 60 {
            let days = minutes / (24 * 60)
            switch language {
            case .english: return "\(days) day\(days == 1 ? "" : "s")"
            case .simplifiedChinese, .traditionalChinese: return "\(days) 天"
            }
        }
        if minutes >= 60 {
            let hours = minutes / 60
            switch language {
            case .english: return "\(hours) hour\(hours == 1 ? "" : "s")"
            case .simplifiedChinese: return "\(hours) 小时"
            case .traditionalChinese: return "\(hours) 小時"
            }
        }
        switch language {
        case .english: return "\(minutes) min"
        case .simplifiedChinese: return "\(minutes) 分钟"
        case .traditionalChinese: return "\(minutes) 分鐘"
        }
    }
}
