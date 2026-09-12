import Foundation

extension AppText {
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

    func compactErrorSummary(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        guard let breakIndex = trimmed.firstIndex(where: { terminators.contains($0) }) else {
            return trimmed
        }
        let firstSentence = trimmed[...breakIndex]
        let cleaned = firstSentence.trimmingCharacters(in: CharacterSet(charactersIn: "。！？.!? "))
        return cleaned.isEmpty ? trimmed : cleaned
    }

    /// Error strings can outlive a language change because account state stores
    /// the rendered message. Re-resolve well-known transport failures at display
    /// time so a Chinese dashboard never inherits a previous English sentence.
    func localizedStoredErrorMessage(_ message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("The connection did not finish")
            || normalized.hasPrefix("这次连接没有完成")
            || normalized.hasPrefix("這次連線沒有完成") {
            return serviceUnavailableMessage()
        }
        if normalized.hasPrefix("The connection took too long")
            || normalized.hasPrefix("这次连接用时较长")
            || normalized.hasPrefix("這次連線用時較長") {
            return timeoutMessage()
        }
        return normalized
    }

    func accountErrorSummary(_ message: String, isRetrying: Bool, hasCachedQuota: Bool) -> String {
        let summary = compactErrorSummary(message)
        guard isRetrying, hasCachedQuota else { return summary }
        return localized(
            english: "Showing previous data · Retrying",
            simplified: "显示上次数据 · 正在重试",
            traditional: "顯示上次資料 · 正在重試"
        )
    }

    func loginMethodPhaseText(_ method: LoginMethod) -> String {
        switch method {
        case .browser:
            return localized(
                english: "Browser opened — finish authorization there",
                simplified: "已打开浏览器，请完成授权",
                traditional: "已開啟瀏覽器，請完成授權"
            )
        case .deviceCode:
            return localized(
                english: "Device-code sign-in — enter the copied code in the browser",
                simplified: "设备码登录中，请在浏览器输入已复制的验证码",
                traditional: "設備碼登入中，請在瀏覽器輸入已複製的驗證碼"
            )
        }
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

    func providerErrorMessage(_ error: ProviderError) -> String {
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
        case .loginRequired(let tool, _):
            return noSignInMessage(tool: tool)
        case .loginIncomplete(let tool, _):
            return loginIncompleteMessage(tool: tool)
        case .cliMissing(let tool, _):
            return missingCommandMessage(tool: tool)
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

    func updateErrorMessage(_ error: UpdateServiceError) -> String {
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

    func httpErrorMessage(statusCode: Int) -> String {
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

    func networkErrorMessage(_ error: URLError) -> String {
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

    func localCredentialProblemMessage() -> String {
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

    func cancelledMessage() -> String {
        localized(
            english: "Cancelled. You can try again anytime.",
            simplified: "已取消。需要时可以重新尝试。",
            traditional: "已取消。需要時可以重新嘗試。"
        )
    }

    func genericRetryMessage() -> String {
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
}
