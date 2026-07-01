import Foundation

/// Canonical status-note strings emitted by the providers.
///
/// A provider records exactly one of these (or a composed/data string) on `QuotaSnapshot.note`, and
/// that canonical value is what gets cached to disk. The UI turns it into the user's language at
/// render time via `AppText.localizedNote(_:)`, so switching language re-localizes cached notes and
/// no localized text is ever frozen into the cache. Simplified Chinese is the canonical/base form,
/// mirroring how `AppText.string` falls back (`traditional ?? simplified`).
enum QuotaNoteCatalog {
    // MARK: Claude Code
    static func claudeStaleLiveData(minutes: Int) -> String {
        "实时接口暂不可用，显示约 \(minutes) 分钟前的真实额度。"
    }
    static let claudeStaleLiveDataPrefix = "实时接口暂不可用，显示约 "
    static let claudeRateLimitReached =
        "Claude Code 已提示 Usage limit reached；QuotaBar 在重置前按 0% 剩余额度显示。"
    static let claudeUsageRateLimited =
        "Claude 账号授权暂时失效，无法获取实时额度；请在终端运行 claude 并执行 /login 重新登录授权后点刷新。"
    static let claudeAwaitingSession =
        "等待 Claude Code 会话同步；打开 Claude Code 并产生一次响应后会显示 5h/7d 用量。"
    static let claudeWindowStale =
        "实时接口暂不可用，已隐藏过期的用量窗口以免显示旧数据；接口恢复或重新登录后自动更新为实时值。"
    static let claudeApiKeyNoWindows =
        "API Key / 第三方提供方模式通常没有 Pro/Max 5h/7d 用量条。"
    static let claudeStatusLineNoWindows =
        "Claude Code statusLine 已同步，但本次快照尚未包含 5h/7d 用量；下一次响应后会自动更新。"

    // MARK: Cursor
    static let cursorLiveUnavailableCache = "实时接口暂不可用，正在显示缓存数据"
    static let cursorLegacyNoStandardFields = "Cursor legacy 接口返回成功，但未识别到标准额度字段"

    // MARK: Codex
    static let codexEmptyQuotaFields = "接口返回成功，但额度字段为空"
    static let codexOAuthFellBackToApiKey = "OAuth 查询失败，已回退 API Key"
    static let codexNoStandardFields = "接口返回成功，但未识别到标准额度字段"

    /// Extracts the minute count from a canonical stale-live-data note, if that is what `raw` is.
    static func staleLiveDataMinutes(from raw: String) -> Int? {
        guard raw.hasPrefix(claudeStaleLiveDataPrefix) else { return nil }
        let digits = raw.dropFirst(claudeStaleLiveDataPrefix.count).prefix { $0.isNumber }
        return Int(digits)
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
                return "Claude Code reported “Usage limit reached”. QuotaBar shows 0% remaining until reset."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "Claude Code 已提示 Usage limit reached；QuotaBar 在重置前以 0% 剩餘額度顯示。"
            }
        case QuotaNoteCatalog.claudeUsageRateLimited:
            switch language {
            case .english:
                return "Your Claude account authorization has expired, so live usage can’t be fetched. Run claude in a terminal, use /login to sign in again, then hit Refresh."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "你的 Claude 帳號授權暫時失效，無法取得即時額度；請在終端機執行 claude 並使用 /login 重新登入授權後按重新整理。"
            }
        case QuotaNoteCatalog.claudeAwaitingSession:
            switch language {
            case .english:
                return "Waiting for a Claude Code session. Open Claude Code and get one response to show 5h/7d usage."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "等待 Claude Code 工作階段同步；開啟 Claude Code 並產生一次回應後會顯示 5h/7d 用量。"
            }
        case QuotaNoteCatalog.claudeWindowStale:
            switch language {
            case .english:
                return "Live data unavailable; expired usage windows are hidden to avoid showing stale numbers. They return once it recovers or you sign in again."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "即時介面暫時無法使用，已隱藏過期的用量視窗以免顯示舊資料；介面恢復或重新登入後會自動更新為即時值。"
            }
        case QuotaNoteCatalog.claudeApiKeyNoWindows:
            switch language {
            case .english:
                return "API key / third-party provider mode usually has no Pro/Max 5h/7d usage bars."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "API Key／第三方提供方模式通常沒有 Pro/Max 5h/7d 用量條。"
            }
        case QuotaNoteCatalog.claudeStatusLineNoWindows:
            switch language {
            case .english:
                return "Claude Code statusLine synced, but this snapshot has no 5h/7d usage yet; it updates after the next response."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "Claude Code statusLine 已同步，但本次快照尚未包含 5h/7d 用量；下一次回應後會自動更新。"
            }
        case QuotaNoteCatalog.cursorLiveUnavailableCache:
            switch language {
            case .english:
                return "Live data unavailable; showing cached data."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "即時介面暫時無法使用，正在顯示快取資料。"
            }
        case QuotaNoteCatalog.cursorLegacyNoStandardFields:
            switch language {
            case .english:
                return "Cursor legacy API succeeded but no standard quota fields were found."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "Cursor legacy 介面回應成功，但未辨識到標準額度欄位。"
            }
        case QuotaNoteCatalog.codexEmptyQuotaFields:
            switch language {
            case .english:
                return "The API succeeded but the quota fields are empty."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "介面回應成功，但額度欄位為空。"
            }
        case QuotaNoteCatalog.codexOAuthFellBackToApiKey:
            switch language {
            case .english:
                return "OAuth lookup failed; fell back to the API key."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "OAuth 查詢失敗，已回退 API Key。"
            }
        case QuotaNoteCatalog.codexNoStandardFields:
            switch language {
            case .english:
                return "The API succeeded but no standard quota fields were found."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "介面回應成功，但未辨識到標準額度欄位。"
            }
        default:
            return raw
        }
    }

    /// A short, one-line display form for notes that call the user to act (currently the expired-
    /// authorization note). Full guidance stays in `localizedNote` (shown as the hover tooltip).
    /// Returns nil for notes with no distinct short form — the caller falls back to the full text.
    func localizedNoteShort(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        switch raw {
        case QuotaNoteCatalog.claudeUsageRateLimited:
            switch language {
            case .english:
                return "Authorization expired — sign in to Claude Code again"
            case .simplifiedChinese:
                return "登录授权已失效，请重新登录 Claude Code"
            case .traditionalChinese:
                return "登入授權已失效，請重新登入 Claude Code"
            }
        default:
            return nil
        }
    }

    /// Whether a note represents a user-actionable problem (needs re-login), so the UI can render it
    /// as a prominent warning (icon + hue) instead of muted metadata.
    func isActionableNote(_ raw: String?) -> Bool {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) == QuotaNoteCatalog.claudeUsageRateLimited
    }

    private func claudeStaleLiveDataText(minutes: Int) -> String {
        switch language {
        case .english:
            return "Live data unavailable; showing the real quota from about \(minutes) min ago."
        case .simplifiedChinese:
            return QuotaNoteCatalog.claudeStaleLiveData(minutes: minutes)
        case .traditionalChinese:
            return "即時介面暫時無法使用，顯示約 \(minutes) 分鐘前的真實額度。"
        }
    }
}
