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
    case restartRequiredTitle
    case settings
    case settingsApp
    case settingsMenuBar
    case menuBarToolsHint
    case settingsRecommendation
    case settingsRefresh
    case show
    case statusBarNoData
    case staleData
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

    private func localized(english: String, simplified: String, traditional: String) -> String {
        switch language {
        case .english:
            return english
        case .simplifiedChinese:
            return simplified
        case .traditionalChinese:
            return traditional
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

    var accountFilterAllTitle: String {
        switch language {
        case .english:
            return "All accounts"
        case .simplifiedChinese:
            return "所有账号"
        case .traditionalChinese:
            return "所有帳號"
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

    var accountFilterAvailableTitle: String {
        switch language {
        case .english:
            return "Available"
        case .simplifiedChinese:
            return "可用账号"
        case .traditionalChinese:
            return "可用帳號"
        }
    }

    func refreshAllAccounts(tool: ToolKind) -> String {
        switch language {
        case .english:
            return "Refresh all \(tool.displayName) accounts"
        case .simplifiedChinese:
            return "刷新全部 \(tool.displayName) 账号"
        case .traditionalChinese:
            return "刷新全部 \(tool.displayName) 帳號"
        }
    }

    func refreshAccount(_ accountName: String) -> String {
        switch language {
        case .english:
            return "Refresh \(accountName)"
        case .simplifiedChinese:
            return "刷新 \(accountName)"
        case .traditionalChinese:
            return "刷新 \(accountName)"
        }
    }

    func useAccount(_ accountName: String) -> String {
        switch language {
        case .english:
            return "Use \(accountName)"
        case .simplifiedChinese:
            return "使用 \(accountName)"
        case .traditionalChinese:
            return "使用 \(accountName)"
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

    func restartRequiredMessage(accountName: String, tool: ToolKind) -> String {
        switch language {
        case .english:
            switch tool {
            case .codex:
                return "Switched to \(accountName). Restart Codex to apply this account."
            case .cursor:
                return "Switched to \(accountName). Restart Cursor to apply this account."
            case .claudeCode:
                return "Switched to \(accountName). Restart Claude Code to apply this account."
            }
        case .simplifiedChinese:
            switch tool {
            case .codex:
                return "已切换到 \(accountName)。请重启 Codex 后生效。"
            case .cursor:
                return "已切换到 \(accountName)。请重启 Cursor 后生效。"
            case .claudeCode:
                return "已切换到 \(accountName)。请重启 Claude Code 后生效。"
            }
        case .traditionalChinese:
            switch tool {
            case .codex:
                return "已切換到 \(accountName)。請重啟 Codex 後生效。"
            case .cursor:
                return "已切換到 \(accountName)。請重啟 Cursor 後生效。"
            case .claudeCode:
                return "已切換到 \(accountName)。請重啟 Claude Code 後生效。"
            }
        }
    }

    func updateAvailableMessage(version: String, currentVersion: String) -> String {
        switch language {
        case .english:
            return "QuotaBar \(version) is available. Current version: \(currentVersion). This unsigned build is distributed through GitHub Releases/Homebrew; macOS may require right-click Open or manual quarantine removal after installation. Download, install, and restart now?"
        case .simplifiedChinese:
            return "发现 QuotaBar \(version)。当前版本：\(currentVersion)。当前版本通过 GitHub Releases/Homebrew 分发且未做 Developer ID 签名，安装后 macOS 可能需要右键打开或手动移除 quarantine。是否立即下载、安装并重启？"
        case .traditionalChinese:
            return "發現 QuotaBar \(version)。目前版本：\(currentVersion)。目前版本透過 GitHub Releases/Homebrew 分發且未做 Developer ID 簽名，安裝後 macOS 可能需要右鍵打開或手動移除 quarantine。是否立即下載、安裝並重啟？"
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
        localized(
            english: "This update did not finish. \(error)",
            simplified: "这次更新没有完成。\(error)",
            traditional: "這次更新沒有完成。\(error)"
        )
    }

    func currentVersionLabel(_ version: String) -> String {
        switch language {
        case .english:
            return "Current \(version)"
        case .simplifiedChinese:
            return "当前版本 \(version)"
        case .traditionalChinese:
            return "目前版本 \(version)"
        }
    }

    func updateAvailableLabel(_ version: String) -> String {
        switch language {
        case .english:
            return "New \(version)"
        case .simplifiedChinese:
            return "新版本 \(version)"
        case .traditionalChinese:
            return "新版本 \(version)"
        }
    }

    func updateNoticeTitle(_ state: AppUpdateBannerState) -> String {
        switch state {
        case .available(let version):
            return localized(
                english: "New version \(version) available",
                simplified: "新版本 \(version) 可用",
                traditional: "新版本 \(version) 可用"
            )
        case .checking:
            return string(.checkingForUpdates)
        case .downloading(let progress):
            if let progress {
                let percent = Int((progress * 100).rounded())
                return localized(
                    english: "Downloading \(percent)%",
                    simplified: "下载 \(percent)%",
                    traditional: "下載 \(percent)%"
                )
            }
            return string(.downloadingUpdate)
        case .installing:
            return string(.installingUpdate)
        case .idle:
            return ""
        }
    }

    func updateNoticeActionLabel(_ state: AppUpdateBannerState) -> String? {
        guard case .available = state else { return nil }
        return string(.update)
    }

    func launchAtLoginFailedMessage(_ error: String) -> String {
        localized(
            english: "Launch at Login was not changed. \(error)",
            simplified: "开机自启还没有改成功。\(error)",
            traditional: "開機自啟還沒有改成功。\(error)"
        )
    }

    func userFacingErrorMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return networkErrorMessage(urlError)
        }
        if let httpError = error as? QuotaHTTPError {
            return httpErrorMessage(statusCode: httpError.statusCode)
        }
        if let providerError = error as? ProviderError {
            return providerErrorMessage(providerError)
        }
        if error is SecretStoreError {
            return localCredentialProblemMessage()
        }
        if let updateError = error as? UpdateServiceError {
            return updateErrorMessage(updateError)
        }
        if error is CancellationError {
            return cancelledMessage()
        }
        return genericRetryMessage()
    }

    func addAccountFailedMessage(_ error: String) -> String {
        localized(
            english: "The account was not added. \(error)",
            simplified: "账号还没有添加成功。\(error)",
            traditional: "帳號還沒有新增成功。\(error)"
        )
    }

    func deleteAccountFailedMessage(_ error: String) -> String {
        localized(
            english: "The account was not deleted. \(error)",
            simplified: "账号还没有删除成功。\(error)",
            traditional: "帳號還沒有刪除成功。\(error)"
        )
    }

    func switchAccountFailedMessage(_ error: String) -> String {
        localized(
            english: "The active account was not changed. \(error)",
            simplified: "当前账号还没有切换成功。\(error)",
            traditional: "目前帳號還沒有切換成功。\(error)"
        )
    }

    func refreshAccountFailedMessage(_ error: String) -> String {
        return error
    }

    private func providerErrorMessage(_ error: ProviderError) -> String {
        switch error {
        case .missingFile:
            return noSignInMessage(tool: nil)
        case .invalidCredentials:
            return signInAgainMessage(tool: nil)
        case .credentialParsingFailed(let tool),
             .tokenExpired(let tool),
             .tokenRefreshFailed(let tool):
            return signInAgainMessage(tool: tool)
        case .cacheCorrupted:
            return cacheProblemMessage()
        case .noUsableCredential(let tool):
            return noSignInMessage(tool: tool)
        case .rateLimited:
            return httpErrorMessage(statusCode: 429)
        case .unsupported(let message),
             .network(let message):
            return classifiedProviderMessage(message)
        }
    }

    private func classifiedProviderMessage(_ raw: String) -> String {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        let tool = toolMentioned(in: message)

        if containsAny(message, ["账号不一致", "帳號不一致", "凭据与当前账号不一致", "返回账号与当前账号不一致"]) {
            return accountMismatchMessage(tool: tool)
        }
        if lower.contains("refresh token") || containsAny(message, ["登录已过期", "登录已失效", "登录续期失败", "token 已", "token 无效"]) {
            return signInAgainMessage(tool: tool)
        }
        if containsAny(message, ["未找到 Cursor 登录状态", "未找到 Cursor 登录 token", "未找到登录文件", "未找到登录信息", "尚未登录"]) {
            return noSignInMessage(tool: tool)
        }
        if containsAny(message, ["未检测到 Cursor 登录完成", "未检测到新的 Cursor 登录凭据", "登录未完成", "登录超时", "浏览器登录超时", "设备码登录超时", "Agent 登录超时"]) {
            return loginIncompleteMessage(tool: tool)
        }
        if containsAny(message, ["未找到 Codex CLI", "未找到 codex 命令", "未找到 Claude Code CLI", "未找到 claude", "未找到命令"]) {
            return missingCommandMessage(tool: tool)
        }
        if containsAny(message, ["Keychain", "登录信息异常", "本地凭据", "登录状态失败", "无法创建数据库快照"]) {
            return localCredentialProblemMessage()
        }
        if containsAny(message, ["用量字段", "返回格式异常", "未识别到用量", "未读取到额度", "未能识别"]) {
            return quotaDataUnavailableMessage()
        }
        if lower.contains("http 429") || containsAny(message, ["请求过于频繁"]) {
            return httpErrorMessage(statusCode: 429)
        }
        if lower.contains("http") || containsAny(message, ["无 HTTP 响应", "查询失败", "刷新失败"]) {
            return serviceUnavailableMessage()
        }
        if containsAny(message, ["命令超时", "请求超时"]) {
            return timeoutMessage()
        }
        if containsAny(message, ["登录失败", "命令执行失败"]) {
            return loginIncompleteMessage(tool: tool)
        }
        return genericRetryMessage()
    }

    private func updateErrorMessage(_ error: UpdateServiceError) -> String {
        switch error {
        case .digestMismatch, .invalidAssetDigest, .untrustedReleaseSource:
            return localized(
                english: "For safety, QuotaBar stopped installing because the update package could not be verified. Try again later, or download from the official release page.",
                simplified: "为确保安全，更新包没有通过校验，QuotaBar 已停止安装。请稍后重试，或从官方发布页下载。",
                traditional: "為確保安全，更新包沒有通過校驗，QuotaBar 已停止安裝。請稍後重試，或從官方發布頁下載。"
            )
        case .installLocationNotWritable:
            return localized(
                english: "QuotaBar does not have permission to update this app location. Check permissions, or install the new version manually.",
                simplified: "QuotaBar 没有权限更新当前位置的应用。请检查权限，或手动安装新版本。",
                traditional: "QuotaBar 沒有權限更新目前位置的應用程式。請檢查權限，或手動安裝新版本。"
            )
        case .installerLaunchFailed:
            return localized(
                english: "The installer did not open. Try again later, or install the new version manually.",
                simplified: "安装程序还没有打开成功。请稍后重试，或手动安装新版本。",
                traditional: "安裝程式還沒有開啟成功。請稍後重試，或手動安裝新版本。"
            )
        case .requestFailed:
            return serviceUnavailableMessage()
        case .invalidReleaseURL,
             .invalidAssetURL,
             .missingReleaseAsset,
             .missingAssetDigest,
             .releaseNotFound:
            return localized(
                english: "The update package is not available yet. Try again later, or check the official release page.",
                simplified: "更新包暂时还没有准备好。请稍后重试，或查看官方发布页。",
                traditional: "更新包暫時還沒有準備好。請稍後重試，或查看官方發布頁。"
            )
        }
    }

    private func httpErrorMessage(statusCode: Int) -> String {
        switch statusCode {
        case 401, 403:
            return signInAgainMessage(tool: nil)
        case 429:
            return localized(
                english: "Refreshes are being slowed down for a bit. QuotaBar will try again automatically.",
                simplified: "刷新暂时变慢，QuotaBar 会稍后自动重试。",
                traditional: "刷新暫時變慢，QuotaBar 會稍後自動重試。"
            )
        case 500...599:
            return serviceUnavailableMessage()
        default:
            return genericRetryMessage()
        }
    }

    private func networkErrorMessage(_ error: URLError) -> String {
        switch error.code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
            .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return localized(
                english: "QuotaBar could not connect securely. Check your proxy, VPN, or certificate settings, then try again.",
                simplified: "QuotaBar 暂时无法建立安全连接。请检查代理、VPN 或证书设置后重试。",
                traditional: "QuotaBar 暫時無法建立安全連線。請檢查代理、VPN 或憑證設定後重試。"
            )
        case .notConnectedToInternet:
            return localized(
                english: "QuotaBar is offline. Connect to the internet, then refresh again.",
                simplified: "QuotaBar 当前离线。请连接网络后再刷新。",
                traditional: "QuotaBar 目前離線。請連接網路後再刷新。"
            )
        case .timedOut:
            return timeoutMessage()
        default:
            return serviceUnavailableMessage()
        }
    }

    private func noSignInMessage(tool: ToolKind?) -> String {
        let name = tool?.displayName
        return localized(
            english: name.map { "\($0) is not signed in yet. Sign in to \($0), then refresh QuotaBar." }
                ?? "This tool is not signed in yet. Sign in first, then refresh QuotaBar.",
            simplified: name.map { "\($0) 还没有登录。请先在 \($0) 登录，然后刷新 QuotaBar。" }
                ?? "还没有找到登录信息。请先在对应工具里登录，然后刷新 QuotaBar。",
            traditional: name.map { "\($0) 還沒有登入。請先在 \($0) 登入，然後刷新 QuotaBar。" }
                ?? "還沒有找到登入資訊。請先在對應工具裡登入，然後刷新 QuotaBar。"
        )
    }

    private func signInAgainMessage(tool: ToolKind?) -> String {
        let name = tool?.displayName
        return localized(
            english: name.map { "\($0) needs a fresh sign-in. Sign in to \($0) again, then refresh QuotaBar." }
                ?? "This sign-in needs to be refreshed. Sign in again, then refresh QuotaBar.",
            simplified: name.map { "\($0) 需要重新登录。请重新登录 \($0)，然后刷新 QuotaBar。" }
                ?? "登录状态需要更新。请重新登录后刷新 QuotaBar。",
            traditional: name.map { "\($0) 需要重新登入。請重新登入 \($0)，然後刷新 QuotaBar。" }
                ?? "登入狀態需要更新。請重新登入後刷新 QuotaBar。"
        )
    }

    private func accountMismatchMessage(tool: ToolKind?) -> String {
        let name = tool?.displayName
        return localized(
            english: name.map { "\($0) is currently using a different account. Switch back in \($0), or add this account again." }
                ?? "The tool is currently using a different account. Switch back there, or add this account again.",
            simplified: name.map { "\($0) 当前使用的是另一个账号。请在 \($0) 切回这个账号，或重新添加。" }
                ?? "当前工具使用的是另一个账号。请在对应工具里切回这个账号，或重新添加。",
            traditional: name.map { "\($0) 目前使用的是另一個帳號。請在 \($0) 切回這個帳號，或重新新增。" }
                ?? "目前工具使用的是另一個帳號。請在對應工具裡切回這個帳號，或重新新增。"
        )
    }

    private func loginIncompleteMessage(tool: ToolKind?) -> String {
        let name = tool?.displayName
        return localized(
            english: name.map { "\($0) sign-in is not complete yet. Finish the browser sign-in, then try again." }
                ?? "Sign-in is not complete yet. Finish the browser sign-in, then try again.",
            simplified: name.map { "\($0) 还没有完成登录。请完成浏览器授权后重试。" }
                ?? "还没有完成登录。请完成浏览器授权后重试。",
            traditional: name.map { "\($0) 還沒有完成登入。請完成瀏覽器授權後重試。" }
                ?? "還沒有完成登入。請完成瀏覽器授權後重試。"
        )
    }

    private func missingCommandMessage(tool: ToolKind?) -> String {
        let name = tool?.displayName
        return localized(
            english: name.map { "QuotaBar needs the \($0) CLI. Install it, or make sure the command works in Terminal." }
                ?? "QuotaBar needs this CLI. Install it, or make sure the command works in Terminal.",
            simplified: name.map { "QuotaBar 需要使用 \($0) CLI。请先安装，或确认命令可在终端运行。" }
                ?? "QuotaBar 需要使用对应 CLI。请先安装，或确认命令可在终端运行。",
            traditional: name.map { "QuotaBar 需要使用 \($0) CLI。請先安裝，或確認命令可在終端機執行。" }
                ?? "QuotaBar 需要使用對應 CLI。請先安裝，或確認命令可在終端機執行。"
        )
    }

    private func localCredentialProblemMessage() -> String {
        localized(
            english: "The local sign-in record needs to be rebuilt. Delete this account from QuotaBar, then add it again.",
            simplified: "本地登录记录需要重新建立。请在 QuotaBar 删除该账号后重新添加。",
            traditional: "本機登入記錄需要重新建立。請在 QuotaBar 刪除該帳號後重新新增。"
        )
    }

    private func cacheProblemMessage() -> String {
        localized(
            english: "The local cache needs to be rebuilt. Refresh once.",
            simplified: "本地缓存需要重新生成。点一次刷新即可。",
            traditional: "本機快取需要重新產生。點一次刷新即可。"
        )
    }

    private func quotaDataUnavailableMessage() -> String {
        localized(
            english: "No quota data is available for this account yet. Refresh later; if it keeps happening, sign in again.",
            simplified: "这个账号暂时还没有可显示的额度数据。请稍后刷新；如果一直没有，请重新登录。",
            traditional: "這個帳號暫時還沒有可顯示的額度資料。請稍後刷新；如果一直沒有，請重新登入。"
        )
    }

    private func serviceUnavailableMessage() -> String {
        localized(
            english: "The connection did not finish. QuotaBar will try again automatically.",
            simplified: "这次连接没有完成，QuotaBar 会稍后自动重试。",
            traditional: "這次連線沒有完成，QuotaBar 會稍後自動重試。"
        )
    }

    private func timeoutMessage() -> String {
        localized(
            english: "The connection took too long. QuotaBar will try again; you can also check the network and retry manually.",
            simplified: "这次连接用时较长，QuotaBar 会稍后再试；也可以检查网络后手动重试。",
            traditional: "這次連線用時較長，QuotaBar 會稍後再試；也可以檢查網路後手動重試。"
        )
    }

    private func cancelledMessage() -> String {
        localized(
            english: "Cancelled. You can try again anytime.",
            simplified: "已取消。需要时可以重新尝试。",
            traditional: "已取消。需要時可以重新嘗試。"
        )
    }

    private func genericRetryMessage() -> String {
        localized(
            english: "This did not finish. Try again later; if it keeps happening, sign in again or add the account again.",
            simplified: "这次操作没有完成。请稍后重试；如果一直出现，请重新登录或重新添加账号。",
            traditional: "這次操作沒有完成。請稍後重試；如果一直出現，請重新登入或重新新增帳號。"
        )
    }

    private func toolMentioned(in message: String) -> ToolKind? {
        let lower = message.lowercased()
        if lower.contains("claude") {
            return .claudeCode
        }
        if lower.contains("cursor") {
            return .cursor
        }
        if lower.contains("codex") {
            return .codex
        }
        return nil
    }

    private func containsAny(_ message: String, _ needles: [String]) -> Bool {
        needles.contains { message.localizedCaseInsensitiveContains($0) }
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
        let isCache = lowerSource.contains("cache")
        let isStale = QuotaFreshness.isStale(snapshot)
        guard isCache || isStale else { return nil }

        let time = formatCompactDateTime(snapshot.updatedAt)
        switch language {
        case .english:
            return isCache ? "Cache \(time)" : "Recent \(time)"
        case .simplifiedChinese:
            return isCache ? "缓存 \(time)" : "最近 \(time)"
        case .traditionalChinese:
            return isCache ? "快取 \(time)" : "最近 \(time)"
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
            .currentBadge: "当前",
            .delete: "删除",
            .deleteLocalOnly: "仅删除本地记录，不影响线上账号。",
            .deletePromptTitle: "删除账号？",
            .emptyAccountsTitle: "暂无账号",
            .emptyAccountsDescription: "可读取本机登录状态，也可添加账号。",
            .emptyAvailableAccountsTitle: "当前筛选无账号",
            .emptyAvailableAccountsDescription: "切换到全部账号查看等待同步、无额度或错误状态的账号。",
            .error: "需处理",
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
            .refreshOnOpen: "打开面板自动刷新",
            .refreshing: "刷新中",
            .recommended: "推荐",
            .recommendedReason: "消耗优先",
            .recommendationStrategy: "推荐策略",
            .remaining: "剩余",
            .restartRequiredTitle: "重启后生效",
            .settings: "设置",
            .settingsApp: "应用",
            .settingsMenuBar: "菜单栏",
            .menuBarToolsHint: "选择在菜单栏显示哪些工具的额度",
            .settingsRecommendation: "推荐",
            .settingsRefresh: "刷新",
            .show: "显示",
            .statusBarNoData: "QuotaBar",
            .staleData: "最近数据",
            .upToDateTitle: "已是最新版本",
            .updateAvailableTitle: "发现新版本",
            .updateCheckFailedTitle: "更新失败",
            .update: "更新",
            .updated: "已更新",
            .verifyingUpdate: "正在校验安装包...",
            .waitingData: "暂无数据",
            .useAccount: "使用"
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
            .currentBadge: "目前",
            .delete: "刪除",
            .deleteLocalOnly: "僅刪除本機記錄，不影響線上帳號。",
            .deletePromptTitle: "刪除帳號？",
            .emptyAccountsTitle: "暫無帳號",
            .emptyAccountsDescription: "可讀取本機登入狀態，也可新增帳號。",
            .emptyAvailableAccountsTitle: "目前篩選無帳號",
            .emptyAvailableAccountsDescription: "切換到全部帳號查看等待同步、無額度或錯誤狀態的帳號。",
            .error: "需處理",
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
            .refreshOnOpen: "打開面板自動刷新",
            .refreshing: "刷新中",
            .recommended: "推薦",
            .recommendedReason: "消耗優先",
            .recommendationStrategy: "推薦策略",
            .remaining: "剩餘",
            .restartRequiredTitle: "重啟後生效",
            .settings: "設定",
            .settingsApp: "應用",
            .settingsMenuBar: "選單列",
            .menuBarToolsHint: "選擇在選單列顯示哪些工具的額度",
            .settingsRecommendation: "推薦",
            .settingsRefresh: "刷新",
            .show: "顯示",
            .statusBarNoData: "QuotaBar",
            .staleData: "最近資料",
            .upToDateTitle: "已是最新版本",
            .updateAvailableTitle: "發現新版本",
            .updateCheckFailedTitle: "更新失敗",
            .update: "更新",
            .updated: "已更新",
            .verifyingUpdate: "正在校驗安裝包...",
            .waitingData: "暫無資料",
            .useAccount: "使用"
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
            .currentBadge: "Active",
            .delete: "Delete",
            .deleteLocalOnly: "Removes local data only. Online access is unchanged.",
            .deletePromptTitle: "Delete account?",
            .emptyAccountsTitle: "No accounts yet",
            .emptyAccountsDescription: "Use local sign-in or add an account.",
            .emptyAvailableAccountsTitle: "No accounts in this filter",
            .emptyAvailableAccountsDescription: "Switch to All to view accounts waiting for sync, out of quota, or in an error state.",
            .error: "Needs action",
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
            .refreshOnOpen: "Refresh on Open",
            .refreshing: "Refreshing",
            .recommended: "Recommended",
            .recommendedReason: "Spend first",
            .recommendationStrategy: "Recommendation",
            .remaining: "Remaining",
            .restartRequiredTitle: "Restart required",
            .settings: "Settings",
            .settingsApp: "App",
            .settingsMenuBar: "Menu Bar",
            .menuBarToolsHint: "Choose which tools show quota in the menu bar",
            .settingsRecommendation: "Recommend",
            .settingsRefresh: "Refresh",
            .show: "Show",
            .statusBarNoData: "QuotaBar",
            .staleData: "Recent",
            .upToDateTitle: "Up to Date",
            .updateAvailableTitle: "Update Available",
            .updateCheckFailedTitle: "Update Failed",
            .update: "Update",
            .updated: "Updated",
            .verifyingUpdate: "Verifying update...",
            .waitingData: "No data",
            .useAccount: "Use"
        ]
    }
}
