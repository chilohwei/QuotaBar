import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Error presentation")
struct ErrorPresentationTests {
    @Test("user-facing errors are grouped and hide low-level details")
    func userFacingErrorsAreGroupedAndHideLowLevelDetails() {
        let text = AppText(language: .simplifiedChinese)

        let loginFailure = text.userFacingErrorMessage(
            ProviderError.unsupported("Codex 登录失败：raw browser stack with tokens")
        )
        #expect(loginFailure == "Codex 还没有完成登录。请完成浏览器授权后重试。")
        #expect(!loginFailure.contains("raw browser"))

        let serviceFailure = text.userFacingErrorMessage(
            ProviderError.network("Codex token 刷新失败，HTTP 500")
        )
        #expect(serviceFailure == "这次连接没有完成，QuotaBar 会稍后自动重试。")
        #expect(!serviceFailure.contains("HTTP 500"))

        let updateFailure = text.userFacingErrorMessage(
            UpdateServiceError.digestMismatch(expected: "abc123", actual: "def456")
        )
        #expect(updateFailure == "为确保安全，更新包没有通过校验，QuotaBar 已停止安装。请稍后重试，或从官方发布页下载。")
        #expect(!updateFailure.contains("abc123"))
    }

    @Test("stored transport errors follow the current dashboard language")
    func storedTransportErrorRelocalizes() {
        let zh = AppText(language: .simplifiedChinese)
        let storedEnglish = "The connection did not finish. QuotaBar will try again automatically."

        #expect(zh.localizedStoredErrorMessage(storedEnglish) == "这次连接没有完成，QuotaBar 会稍后自动重试。")
        #expect(
            zh.accountErrorSummary(storedEnglish, isRetrying: true, hasCachedQuota: true)
                == "显示上次数据 · 正在重试"
        )
    }

    @Test("compact error summary keeps only the actionable first sentence")
    func compactErrorSummaryFirstSentence() {
        let zh = AppText(language: .simplifiedChinese)
        #expect(zh.compactErrorSummary("Claude Code 需要重新登录。请重新登录 Claude Code，然后刷新 QuotaBar。") == "Claude Code 需要重新登录")
        #expect(zh.compactErrorSummary("本地登录记录需要重新建立。请在 QuotaBar 删除该账号后重新添加。") == "本地登录记录需要重新建立")

        let en = AppText(language: .english)
        #expect(en.compactErrorSummary("Claude Code needs a fresh sign-in. Sign in to Claude Code again, then refresh QuotaBar.") == "Claude Code needs a fresh sign-in")

        // No sentence break: returned unchanged.
        #expect(zh.compactErrorSummary("刷新中") == "刷新中")
    }
}
