import AppKit
import Combine
import SwiftUI

private final class DashboardPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: DashboardLayout.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let dashboardPanel: DashboardPanel
    private var eventMonitor: Any?
    private let appState: AppState
    private let updateService = UpdateService()
    private let launchAtLoginService = LaunchAtLoginService()
    private var isCheckingForUpdates = false
    private var isInstallingUpdate = false
    private var availableRelease: UpdateRelease?
    private var updateProgressWindow: NSWindow?
    private var updateProgressIndicator: NSProgressIndicator?
    private var updateProgressTitleLabel: NSTextField?
    private var updateProgressDetailLabel: NSTextField?
    private var pendingPanelPresentationTask: Task<Void, Never>?
    private var statusBarContentView: StatusBarQuotaContentView?
    private var isStatusTitleUpdateScheduled = false
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.dashboardPanel = DashboardPanel()
        super.init()

        appState.registerUpdateActions(
            checkForUpdates: { [weak self] in
                Task { @MainActor in
                    self?.performUpdateCheck(showFeedback: true)
                }
            },
            installAvailableUpdate: { [weak self] in
                Task { @MainActor in
                    self?.installAvailableUpdateFromDashboard()
                }
            }
        )
        appState.registerLaunchAtLoginActions(
            isEnabled: { [weak self] in
                self?.launchAtLoginService.isEnabled ?? false
            },
            setEnabled: { [weak self] enabled in
                self?.setLaunchAtLoginEnabled(enabled)
            }
        )

        configureStatusItem()
        configureDashboardPanel()
        performUpdateCheck(showFeedback: false)
    }

    func shutdown() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        pendingPanelPresentationTask?.cancel()
        pendingPanelPresentationTask = nil
        dashboardPanel.close()
    }

    func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        let inputs = ToolKind.allCases.compactMap { tool -> StatusBarQuotaInput? in
            guard appState.isToolVisibleInMenuBar(tool),
                  let active = appState.activeAccount(for: tool),
                  let quota = appState.quotaByAccount[active.id] else {
                return nil
            }
            return StatusBarQuotaInput(tool: tool, accountName: active.name, quota: quota)
        }
        let entries = StatusBarQuotaPresenter.entries(for: inputs)
        let display = entries.isEmpty ? nil : StatusBarQuotaDisplay(items: entries)

        button.toolTip = StatusBarQuotaPresenter.tooltip(for: entries, text: appState.text)
        button.contentTintColor = nil
        statusBarContentView?.configure(display: display)
        statusItem.length = display?.preferredStatusItemLength ?? NSStatusItem.squareLength
        button.setAccessibilityLabel(button.toolTip ?? appState.text.string(.statusBarNoData))
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        applyMenuBarIcon(to: button)
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        updateStatusTitle()
    }

    private func configureDashboardPanel() {
        let host = NSHostingController(
            rootView: DashboardView(appState: appState)
                .frame(width: DashboardLayout.panelWidth, height: DashboardLayout.preferredPanelHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        host.view.frame = NSRect(origin: .zero, size: DashboardLayout.panelSize)
        host.preferredContentSize = DashboardLayout.panelSize
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = 12
        host.view.layer?.cornerCurve = .continuous
        host.view.layer?.masksToBounds = true

        dashboardPanel.contentViewController = host
        dashboardPanel.delegate = self
        dashboardPanel.setContentSize(DashboardLayout.panelSize)
        dashboardPanel.minSize = DashboardLayout.panelSize
        dashboardPanel.maxSize = DashboardLayout.panelSize
        dashboardPanel.isReleasedWhenClosed = false
        dashboardPanel.isOpaque = false
        dashboardPanel.backgroundColor = .clear
        dashboardPanel.hasShadow = true
        dashboardPanel.level = .statusBar
        dashboardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.dashboardPanel.isVisible else { return }
                self.dashboardPanel.close()
            }
        }

        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleStatusTitleUpdate()
                guard self.dashboardPanel.isVisible else { return }
                self.updateDashboardPanelSize()
                DispatchQueue.main.async { [weak self] in
                    self?.updateDashboardPanelSize()
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleStatusTitleUpdate() {
        guard !isStatusTitleUpdateScheduled else { return }
        isStatusTitleUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isStatusTitleUpdateScheduled = false
            self.updateStatusTitle()
        }
    }

    @objc private func handleStatusItemClick(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else {
            toggleDashboardPanel(sender)
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu()
            return
        }

        toggleDashboardPanel(sender)
    }

    @objc private func toggleDashboardPanel(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if dashboardPanel.isVisible {
            pendingPanelPresentationTask?.cancel()
            pendingPanelPresentationTask = nil
            dashboardPanel.close()
        } else {
            pendingPanelPresentationTask?.cancel()
            // Show the panel immediately with whatever data is already cached, then
            // do the (potentially slow) account sync / refresh in the background. The
            // dashboard is bound to appState and updates reactively as fresh data
            // arrives, so awaiting the preparation before presenting only added
            // perceived latency to every click.
            appState.refreshLaunchAtLoginState()
            presentDashboardPanel(relativeTo: button)
            pendingPanelPresentationTask = Task { [weak self] in
                guard let self else { return }
                await self.appState.prepareSelectedToolForDashboardPresentation()
                self.pendingPanelPresentationTask = nil
            }
        }
    }

    private func updateDashboardPanelSize() {
        dashboardPanel.setContentSize(DashboardLayout.panelSize)
        dashboardPanel.contentViewController?.view.frame = NSRect(origin: .zero, size: DashboardLayout.panelSize)
        dashboardPanel.contentViewController?.preferredContentSize = DashboardLayout.panelSize
    }

    private func presentDashboardPanel(relativeTo button: NSStatusBarButton) {
        updateDashboardPanelSize()
        dashboardPanel.setFrame(dashboardPanelFrame(relativeTo: button), display: false)
        dashboardPanel.makeKeyAndOrderFront(nil)
        appState.setDashboardVisible(true)
        updateDashboardPanelSize()
        DispatchQueue.main.async { [weak self] in
            self?.updateDashboardPanelSize()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === dashboardPanel else { return }
        appState.setDashboardVisible(false)
    }

    private func dashboardPanelFrame(relativeTo button: NSStatusBarButton) -> NSRect {
        let statusFrame: NSRect
        if let window = button.window {
            statusFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        } else {
            statusFrame = NSRect(
                x: NSScreen.main?.visibleFrame.midX ?? 0,
                y: NSScreen.main?.visibleFrame.maxY ?? 0,
                width: NSStatusItem.squareLength,
                height: NSStatusItem.squareLength
            )
        }

        let screen = NSScreen.screens.first { $0.frame.intersects(statusFrame) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panelSize = DashboardLayout.panelSize
        let margin: CGFloat = 8
        let gap: CGFloat = 6

        var originX = statusFrame.midX - panelSize.width / 2
        originX = min(max(originX, visibleFrame.minX + margin), visibleFrame.maxX - panelSize.width - margin)

        let originY = max(visibleFrame.minY + margin, statusFrame.minY - panelSize.height - gap)
        return NSRect(origin: NSPoint(x: originX, y: originY), size: panelSize)
    }

    private func applyMenuBarIcon(to button: NSStatusBarButton) {
        let iconSize: CGFloat = 17.5
        let icon = Branding.makeMenuBarIcon(size: iconSize)
        icon.size = NSSize(width: iconSize, height: iconSize)
        button.image = nil
        button.title = ""

        let contentView = StatusBarQuotaContentView(fallbackIcon: icon)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            contentView.heightAnchor.constraint(equalToConstant: StatusBarQuotaContentView.preferredHeight)
        ])
        statusBarContentView = contentView
    }

    private func showContextMenu() {
        if dashboardPanel.isVisible {
            dashboardPanel.close()
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

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

        let quitTitle: String
        switch appState.language {
        case .english:
            quitTitle = "Quit"
        case .simplifiedChinese:
            quitTitle = "退出"
        case .traditionalChinese:
            quitTitle = "退出"
        }
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        guard let button = statusItem.button,
              let window = button.window else { return }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = window.convertToScreen(buttonRectInWindow)
        let anchor = NSPoint(x: buttonRectOnScreen.minX, y: buttonRectOnScreen.minY - 2)
        menu.popUp(positioning: nil, at: anchor, in: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func checkForUpdates() {
        performUpdateCheck(showFeedback: true)
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLoginEnabled(!launchAtLoginService.isEnabled)
    }

    private func setLaunchAtLoginEnabled(_ enabled: Bool) {
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

    private func showUpdateResult(_ result: UpdateCheckResult) {
        switch result {
        case .upToDate(let currentVersion, let latestVersion):
            availableRelease = nil
            appState.updateBannerState = .idle
            showInformationalAlert(
                title: appState.text.string(.upToDateTitle),
                message: appState.text.upToDateMessage(
                    currentVersion: currentVersion,
                    latestVersion: latestVersion
                )
            )
        case .updateAvailable(let release):
            availableRelease = release
            appState.updateBannerState = .available(version: release.version)
            showUpdateAvailableAlert(release)
        }
    }

    private func showUpdateAvailableAlert(_ release: UpdateRelease) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = appState.text.string(.updateAvailableTitle)
        alert.informativeText = appState.text.updateAvailableMessage(
            version: release.version,
            currentVersion: release.currentVersion
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: appState.text.string(.downloadAndInstall))
        alert.addButton(withTitle: appState.text.string(.cancel))

        if alert.runModal() == .alertFirstButtonReturn {
            performUpdateInstall(release)
        }
    }

    private func showUpdateError(_ error: Error) {
        showInformationalAlert(
            title: appState.text.string(.updateCheckFailedTitle),
            message: appState.text.updateCheckFailedMessage(resolvedErrorMessage(error))
        )
    }

    private func showInformationalAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: appState.text.string(.ok))
        alert.runModal()
    }

    private func resolvedErrorMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let text = localized.errorDescription,
           !text.isEmpty {
            return text
        }
        return error.localizedDescription
    }

    private func performUpdateCheck(showFeedback: Bool) {
        guard !isCheckingForUpdates, !isInstallingUpdate else { return }
        isCheckingForUpdates = true
        appState.updateBannerState = .checking
        let updateService = updateService

        Task { [weak self] in
            do {
                let result = try await updateService.checkForUpdates()
                await MainActor.run {
                    guard let self else { return }
                    self.isCheckingForUpdates = false
                    if showFeedback {
                        self.showUpdateResult(result)
                    } else {
                        switch result {
                        case .upToDate:
                            self.availableRelease = nil
                            self.appState.updateBannerState = .idle
                        case .updateAvailable(let release):
                            self.availableRelease = release
                            self.appState.updateBannerState = .available(version: release.version)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isCheckingForUpdates = false
                    if let release = self.availableRelease {
                        self.appState.updateBannerState = .available(version: release.version)
                    } else {
                        self.appState.updateBannerState = .idle
                    }
                    if showFeedback {
                        self.showUpdateError(error)
                    }
                }
            }
        }
    }

    private func installAvailableUpdateFromDashboard() {
        guard !isInstallingUpdate else { return }
        if let release = availableRelease {
            performUpdateInstall(release)
        } else {
            performUpdateCheck(showFeedback: true)
        }
    }

    private func performUpdateInstall(_ release: UpdateRelease) {
        guard !isInstallingUpdate else { return }
        isInstallingUpdate = true
        appState.updateBannerState = .downloading(progress: nil)
        let updateService = updateService
        let progressRelay = UpdateProgressRelay(controller: self)
        showUpdateProgressWindow(release: release)

        Task { [weak self] in
            do {
                try await updateService.installAndRelaunch(release) { progress in
                    progressRelay.report(progress)
                }
                await MainActor.run {
                    guard let self else { return }
                    self.updateProgressTitleLabel?.stringValue = self.appState.text.string(.installingUpdate)
                    self.updateProgressDetailLabel?.stringValue = self.progressDetailText(bytesWritten: nil, totalBytes: nil)
                    self.updateProgressIndicator?.isIndeterminate = true
                    self.updateProgressIndicator?.startAnimation(nil)
                    self.isInstallingUpdate = false
                    self.appState.updateBannerState = .installing
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isInstallingUpdate = false
                    if let release = self.availableRelease {
                        self.appState.updateBannerState = .available(version: release.version)
                    } else {
                        self.appState.updateBannerState = .idle
                    }
                    self.closeUpdateProgressWindow()
                    self.showUpdateError(error)
                }
            }
        }
    }

    private func showUpdateProgressWindow(release: UpdateRelease) {
        NSApp.activate(ignoringOtherApps: true)
        closeUpdateProgressWindow()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 134),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = appState.text.string(.downloadAndInstall)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 134))
        container.material = .contentBackground
        container.blendingMode = .withinWindow
        container.state = .active

        let titleLabel = NSTextField(labelWithString: appState.text.string(.downloadingUpdate))
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 20, y: 92, width: 320, height: 18)

        let detailLabel = NSTextField(labelWithString: release.assetName)
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.frame = NSRect(x: 20, y: 70, width: 320, height: 16)

        let progressIndicator = NSProgressIndicator(frame: NSRect(x: 20, y: 42, width: 320, height: 14))
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0

        let footerLabel = NSTextField(labelWithString: progressDetailText(bytesWritten: 0, totalBytes: nil))
        footerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.alignment = .right
        footerLabel.frame = NSRect(x: 20, y: 20, width: 320, height: 14)

        container.addSubview(titleLabel)
        container.addSubview(detailLabel)
        container.addSubview(progressIndicator)
        container.addSubview(footerLabel)
        window.contentView = container

        updateProgressWindow = window
        updateProgressIndicator = progressIndicator
        updateProgressTitleLabel = titleLabel
        updateProgressDetailLabel = footerLabel
        window.makeKeyAndOrderFront(nil)
    }

    fileprivate func updateDownloadProgress(_ progress: UpdateDownloadProgress) {
        updateProgressTitleLabel?.stringValue = appState.text.string(.downloadingUpdate)
        updateProgressDetailLabel?.stringValue = progressDetailText(
            bytesWritten: progress.bytesWritten,
            totalBytes: progress.totalBytes
        )
        appState.updateBannerState = .downloading(progress: progress.fractionCompleted)
        guard let fraction = progress.fractionCompleted else {
            updateProgressIndicator?.isIndeterminate = true
            updateProgressIndicator?.startAnimation(nil)
            return
        }
        if fraction >= 1 {
            updateProgressTitleLabel?.stringValue = appState.text.string(.verifyingUpdate)
            appState.updateBannerState = .installing
        }
        updateProgressIndicator?.stopAnimation(nil)
        updateProgressIndicator?.isIndeterminate = false
        updateProgressIndicator?.doubleValue = fraction
    }

    private func closeUpdateProgressWindow() {
        updateProgressWindow?.close()
        updateProgressWindow = nil
        updateProgressIndicator = nil
        updateProgressTitleLabel = nil
        updateProgressDetailLabel = nil
    }

    private func progressDetailText(bytesWritten: Int64?, totalBytes: Int64?) -> String {
        guard let bytesWritten else {
            return appState.text.string(.verifyingUpdate)
        }
        let written = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
        guard let totalBytes, totalBytes > 0 else {
            return written
        }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let percent = Int((Double(bytesWritten) / Double(totalBytes) * 100).rounded())
        return "\(written) / \(total) · \(percent)%"
    }
}

private final class UpdateProgressRelay: @unchecked Sendable {
    weak var controller: StatusBarController?

    init(controller: StatusBarController) {
        self.controller = controller
    }

    func report(_ progress: UpdateDownloadProgress) {
        Task { @MainActor [weak controller] in
            controller?.updateDownloadProgress(progress)
        }
    }
}
