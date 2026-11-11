extension AppText {
    var balanceTitle: String {
        localized(english: "API Balance", simplified: "API 余额", traditional: "API 餘額")
    }

    var balanceDetails: String {
        localized(english: "Balance Details", simplified: "余额明细", traditional: "餘額明細")
    }

    var toppedUpBalance: String {
        localized(english: "Topped-up balance", simplified: "充值余额", traditional: "儲值餘額")
    }

    var grantedBalance: String {
        localized(english: "Granted balance", simplified: "赠金余额", traditional: "贈金餘額")
    }

    var balanceUnavailable: String {
        localized(
            english: "Balance unavailable for API calls",
            simplified: "余额暂不可用于 API 调用",
            traditional: "餘額暫不可用於 API 呼叫"
        )
    }

    var replaceDeepSeekKey: String {
        localized(english: "Replace API Key", simplified: "更换 API Key", traditional: "更換 API Key")
    }

    var deepSeekInvalidKey: String {
        localized(
            english: "Check your DeepSeek API key and try again.",
            simplified: "请检查 DeepSeek API Key 后重试。",
            traditional: "請檢查 DeepSeek API Key 後再試一次。"
        )
    }

    var deepSeekUnreadableKey: String {
        localized(
            english: "Couldn’t read the API Key from Keychain. Choose Replace API Key in the account menu.",
            simplified: "无法从钥匙串读取 API Key，请在账号菜单中选择「更换 API Key」。",
            traditional: "無法從鑰匙圈讀取 API Key，請在帳號選單中選擇「更換 API Key」。"
        )
    }

    var deepSeekDuplicateKey: String {
        localized(
            english: "This API key is already saved for another account.",
            simplified: "此 API Key 已用于另一个账号。",
            traditional: "此 API Key 已用於另一個帳號。"
        )
    }

    var deepSeekAccountName: String {
        localized(english: "DeepSeek Account", simplified: "DeepSeek 账号", traditional: "DeepSeek 帳號")
    }

    var optionalAccountName: String {
        localized(english: "Account name (optional)", simplified: "账号备注（可选）", traditional: "帳號備註（選填）")
    }

    var configuredDeepSeekBackend: String {
        localized(english: "Configured backend · DeepSeek", simplified: "配置后端 · DeepSeek", traditional: "設定後端 · DeepSeek")
    }

    var importDeepSeekKey: String {
        localized(english: "Import DeepSeek API Key", simplified: "导入 DeepSeek API Key", traditional: "匯入 DeepSeek API Key")
    }

    func deepSeekKeyVisibilityAction(showsKey: Bool) -> String {
        if showsKey {
            return localized(english: "Hide API Key", simplified: "隐藏 API Key", traditional: "隱藏 API Key")
        }
        return localized(english: "Show API Key", simplified: "显示 API Key", traditional: "顯示 API Key")
    }
}
