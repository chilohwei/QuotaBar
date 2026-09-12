import Foundation

// Maps raw provider/network errors to user-facing severity and messages.
extension AppState {
    func resolvedErrorMessage(_ error: Error) -> String {
        text.userFacingErrorMessage(error)
    }

    func retryDeadline(for error: Error) -> Date? {
        if let httpError = error as? QuotaHTTPError,
           let retryAfter = httpError.retryAfter,
           retryAfter > Date() {
            return retryAfter
        }
        if case ProviderError.rateLimited(_, let retryAfter) = error,
           let retryAfter,
           retryAfter > Date() {
            return retryAfter
        }
        return nil
    }

    func errorRequiresUserAction(_ error: Error) -> Bool {
        if error is SecretStoreError {
            return true
        }
        if let httpError = error as? QuotaHTTPError {
            return httpError.statusCode == 401 || httpError.statusCode == 403
        }
        guard let providerError = error as? ProviderError else {
            return false
        }

        if providerError.requiresUserAction {
            return true
        }

        switch providerError {
        case .unsupported(let message),
             .network(let message):
            // Legacy keyword fallback for messages not yet migrated to semantic cases.
            return providerMessageRequiresUserAction(message)
        default:
            return false
        }
    }

    func providerMessageRequiresUserAction(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("http 429")
            || lower.contains("http 5")
            || containsAny(message, ["请求过于频繁", "命令超时", "请求超时", "无 HTTP 响应", "查询失败", "刷新失败"]) {
            return false
        }

        return lower.contains("refresh token")
            || containsAny(message, [
                "账号不一致",
                "帳號不一致",
                "凭据与当前账号不一致",
                "返回账号与当前账号不一致",
                "登录已过期",
                "登录已失效",
                "登录续期失败",
                "token 已",
                "token 无效",
                "未找到 Cursor 登录状态",
                "未找到 Cursor 登录 token",
                "未找到登录文件",
                "未找到登录信息",
                "尚未登录",
                "未检测到 Cursor 登录完成",
                "未检测到新的 Cursor 登录凭据",
                "登录未完成",
                "登录超时",
                "浏览器登录超时",
                "设备码登录超时",
                "Agent 登录超时",
                "登录失败",
                "未找到 Codex CLI",
                "未找到 codex 命令",
                "未找到 Claude Code CLI",
                "未找到 claude",
                "未找到命令",
                "Keychain",
                "登录信息异常",
                "本地凭据",
                "登录状态失败",
                "无法创建数据库快照"
            ])
    }

    func containsAny(_ message: String, _ needles: [String]) -> Bool {
        needles.contains { message.localizedCaseInsensitiveContains($0) }
    }

}
