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
        "暂时无法刷新，显示的是约 \(minutes) 分钟前的额度。"
    }
    static let claudeStaleLiveDataPrefix = "暂时无法刷新，显示的是约 "
    static let claudeRateLimitReached =
        "本轮额度已用完，需等到重置时间后自动恢复。"
    static let claudeUsageRateLimited =
        "Claude 登录授权已失效，无法获取实时额度；请在终端运行 claude 并执行 /login 重新登录后点刷新。"
    static let claudeAwaitingSession =
        "还没有额度数据，在 Claude Code 里用一次后即可显示。"
    static let claudeWindowStale =
        "暂时无法获取最新额度，恢复后会自动更新；可点刷新重试。"
    static let claudeApiKeyNoWindows =
        "当前为 API Key / 第三方模式，没有 5 小时 / 每周额度限制。"
    static let claudeStatusLineNoWindows =
        "额度数据同步中，在 Claude Code 里用一次后会显示。"

    // MARK: Cursor
    static let cursorLiveUnavailableCache = "暂时无法刷新，显示的是最近一次的额度。"
    static let cursorLegacyNoStandardFields = "未能读取到额度数据，可能是该账号类型暂不支持。"

    // MARK: Codex
    static let codexEmptyQuotaFields = "暂时没有额度数据。"
    static let codexOAuthFellBackToApiKey = "OAuth 暂时不可用，已改用 API Key 获取额度。"
    static let codexNoStandardFields = "未能识别到额度数据。"

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
                return "You’ve used up this window’s quota. It comes back at the reset time."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "本輪額度已用完，需等到重置時間後自動恢復。"
            }
        case QuotaNoteCatalog.claudeUsageRateLimited:
            switch language {
            case .english:
                return "Your Claude sign-in has expired, so live usage can’t load. Run claude in a terminal, use /login to sign in again, then hit Refresh."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "你的 Claude 登入授權已失效，無法取得即時額度；請在終端機執行 claude 並使用 /login 重新登入後按重新整理。"
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
        case QuotaNoteCatalog.claudeWindowStale:
            switch language {
            case .english:
                return "Can’t get the latest quota right now — it’ll update once it recovers. Try Refresh."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "暫時無法取得最新額度，恢復後會自動更新；可點重新整理重試。"
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
                return "Can’t refresh right now — showing your most recent quota."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "暫時無法刷新，顯示的是最近一次的額度。"
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
                return "OAuth unavailable — using your API key instead."
            case .simplifiedChinese:
                return raw
            case .traditionalChinese:
                return "OAuth 暫時無法使用，已改用 API Key 取得額度。"
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

    /// A short, one-line display form for notes that call the user to act (currently the expired
    /// sign-in note). Full guidance stays in `localizedNote` (shown as the hover tooltip). Returns
    /// nil for notes with no distinct short form — the caller falls back to the full text.
    func localizedNoteShort(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        switch raw {
        case QuotaNoteCatalog.claudeUsageRateLimited:
            switch language {
            case .english:
                return "Sign-in expired — sign in to Claude Code again"
            case .simplifiedChinese:
                return "登录已失效，请重新登录 Claude Code"
            case .traditionalChinese:
                return "登入已失效，請重新登入 Claude Code"
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
            return "Can’t refresh right now — showing your quota from about \(minutes) min ago."
        case .simplifiedChinese:
            return QuotaNoteCatalog.claudeStaleLiveData(minutes: minutes)
        case .traditionalChinese:
            return "暫時無法刷新，顯示的是約 \(minutes) 分鐘前的額度。"
        }
    }
}
