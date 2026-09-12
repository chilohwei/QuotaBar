import AppKit
import Combine
import SwiftUI

extension StatusBarController {
    func showContextMenu() {
        if dashboardPanel.isVisible {
            dashboardPanel.close()
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        appendAccountSwitchItems(to: menu)

        let languageItem = NSMenuItem(title: appState.text.string(.language), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.displayName, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = appState.language == language ? .on : .off
            languageMenu.addItem(item)
        }
        menu.addItem(languageItem)
        menu.setSubmenu(languageMenu, for: languageItem)
        menu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(
            title: appState.text.string(.launchAtLogin),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        launchAtLoginItem.state = launchAtLoginService.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        let updateTitle: String
        if isInstallingUpdate {
            updateTitle = appState.text.string(.installingUpdate)
        } else if isCheckingForUpdates {
            updateTitle = appState.text.string(.checkingForUpdates)
        } else {
            updateTitle = appState.text.string(.checkForUpdates)
        }
        let updateItem = NSMenuItem(title: updateTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = !isCheckingForUpdates && !isInstallingUpdate
        menu.addItem(updateItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: appState.text.string(.quit), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        guard let button = statusItem.button,
              let window = button.window else { return }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = window.convertToScreen(buttonRectInWindow)
        let anchor = NSPoint(x: buttonRectOnScreen.minX, y: buttonRectOnScreen.minY - 2)
        menu.popUp(positioning: nil, at: anchor, in: nil)
    }

    private func appendAccountSwitchItems(to menu: NSMenu) {
        var addedItems = false

        if let recommended = appState.recommendedAccount(for: appState.selectedTool),
           appState.activeAccountByTool[appState.selectedTool] != recommended.id {
            let item = NSMenuItem(
                title: appState.text.switchToRecommendedAccount(recommended.name),
                action: #selector(activateAccountFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = recommended.id.uuidString
            menu.addItem(item)
            addedItems = true
        }

        let switchMenu = NSMenu()
        for tool in ToolKind.allCases {
            let toolAccounts = appState.accounts(for: tool)
            guard !toolAccounts.isEmpty else { continue }

            let activeID = appState.activeAccountByTool[tool]
            let recommendedID = appState.recommendedAccount(for: tool)?.id
            let toolItem = NSMenuItem(title: tool.displayName, action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            for account in toolAccounts {
                let title = account.id == recommendedID && account.id != activeID
                    ? "\(account.name) · \(appState.text.string(.recommended))"
                    : account.name
                let item = NSMenuItem(title: title, action: #selector(activateAccountFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.state = account.id == activeID ? .on : .off
                item.representedObject = account.id.uuidString
                submenu.addItem(item)
            }

            switchMenu.addItem(toolItem)
            switchMenu.setSubmenu(submenu, for: toolItem)
        }

        if !switchMenu.items.isEmpty {
            let switchItem = NSMenuItem(title: appState.text.string(.switchAccount), action: nil, keyEquivalent: "")
            menu.addItem(switchItem)
            menu.setSubmenu(switchMenu, for: switchItem)
            addedItems = true
        }

        if addedItems {
            menu.addItem(.separator())
        }
    }

    @objc private func activateAccountFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let accountID = UUID(uuidString: raw),
              let account = appState.accounts.first(where: { $0.id == accountID }) else {
            return
        }
        appState.activateAccount(account)
    }

    // Account switches take effect only after the tool re-reads its credentials; this dialog
    // offers to do the restart right away and is the only prompt (no notice bar alongside).
    // With the dashboard open it attaches as a sheet — the panel floats at status-bar level,
    // so a free-standing modal window would end up behind it.
    func presentRestartPrompt(tool: ToolKind, message: String) {
        let alert = NSAlert()
        alert.messageText = appState.text.string(.restartRequiredTitle)
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: appState.text.string(.restartNow))
        alert.addButton(withTitle: appState.text.string(.later))

        if dashboardPanel.isVisible {
            isPresentingRestartPrompt = true
            alert.beginSheetModal(for: dashboardPanel) { [weak self] response in
                guard let self else { return }
                self.isPresentingRestartPrompt = false
                if response == .alertFirstButtonReturn {
                    self.appState.restartToolNow(tool)
                }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                appState.restartToolNow(tool)
            }
        }
    }

    func restartToolApp(_ tool: ToolKind) {
        switch tool {
        case .cursor:
            restartCursorApp()
        case .codex:
            CodexRestartService.restartCodex()
        case .claudeCode:
            break
        }
    }

    // Gracefully quits and relaunches the Cursor GUI app.
    // `terminate()` lets the app prompt for unsaved work; relaunch happens only
    // after it actually exits, so a cancelled quit leaves everything untouched.
    private func restartCursorApp() {
        let running = NSWorkspace.shared.runningApplications.first { app in
            app.bundleURL?.lastPathComponent == "Cursor.app" || app.localizedName == "Cursor"
        }

        guard let running, let bundleURL = running.bundleURL else {
            let installed = URL(fileURLWithPath: "/Applications/Cursor.app")
            if FileManager.default.fileExists(atPath: installed.path) {
                NSWorkspace.shared.openApplication(at: installed, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            return
        }

        running.terminate()
        Task { @MainActor in
            for _ in 0 ..< 40 where !running.isTerminated {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard running.isTerminated else {
                AppLog.app.info("Cursor did not quit (likely unsaved work); skipping relaunch")
                return
            }
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc func checkForUpdates() {
        performUpdateCheck(showFeedback: true)
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLoginEnabled(!launchAtLoginService.isEnabled)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(enabled)
        } catch {
            showInformationalAlert(
                title: appState.text.string(.launchAtLoginFailedTitle),
                message: appState.text.launchAtLoginFailedMessage(resolvedErrorMessage(error))
            )
        }
        appState.refreshLaunchAtLoginState()
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else {
            return
        }
        appState.setLanguage(language)
        updateStatusTitle()
    }
}
