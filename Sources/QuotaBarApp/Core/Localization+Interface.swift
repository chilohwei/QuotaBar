import Foundation

extension AppText {
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
            return "QuotaBar \(version) is available. Current version: \(currentVersion). This unsigned build is distributed through GitHub Releases; macOS may require right-click Open or manual quarantine removal after installation. Download, install, and restart now?"
        case .simplifiedChinese:
            return "发现 QuotaBar \(version)。当前版本：\(currentVersion)。当前版本通过 GitHub Releases 分发且未做 Developer ID 签名，安装后 macOS 可能需要右键打开或手动移除 quarantine。是否立即下载、安装并重启？"
        case .traditionalChinese:
            return "發現 QuotaBar \(version)。目前版本：\(currentVersion)。目前版本透過 GitHub Releases 分發且未做 Developer ID 簽名，安裝後 macOS 可能需要右鍵打開或手動移除 quarantine。是否立即下載、安裝並重啟？"
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

    func launchAtLoginFailedMessage(_ error: String) -> String {
        localized(
            english: "Launch at Login was not changed. \(error)",
            simplified: "开机自启还没有改成功。\(error)",
            traditional: "開機自啟還沒有改成功。\(error)"
        )
    }
}
