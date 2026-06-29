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

        let entries = statusBarQuotaEntries()
        let display = entries.isEmpty ? nil : StatusBarQuotaDisplay(items: entries)

        button.toolTip = statusBarTooltip(for: entries)
        button.contentTintColor = nil
        statusBarContentView?.configure(display: display)
        statusItem.length = display?.preferredStatusItemLength ?? NSStatusItem.squareLength
        button.setAccessibilityLabel(button.toolTip ?? appState.text.string(.statusBarNoData))
    }

    private func statusBarQuotaEntries() -> [StatusBarQuotaEntry] {
        ToolKind.allCases.compactMap { tool in
            guard appState.isToolVisibleInMenuBar(tool),
                  let active = appState.activeAccount(for: tool),
                  let quota = appState.quotaByAccount[active.id] else {
                return nil
            }

            // Two stacked lines next to the logo: top = primary window (e.g. 5h),
            // bottom = secondary window (e.g. weekly). Read live from the snapshot.
            let lines = [quota.primaryPanelMetric, quota.secondaryPanelMetric]
                .compactMap(quotaLine(for:))
            guard !lines.isEmpty else { return nil }

            let remainingRatio = statusBarRemainingRatio(from: quota) ?? 0
            return StatusBarQuotaEntry(
                tool: tool,
                accountName: active.name,
                remainingPercent: Int(max(remainingRatio * 100, 0).rounded()),
                lines: lines
            )
        }
    }

    private func statusBarRemainingRatio(from quota: QuotaSnapshot) -> Double? {
        quota.statusBarMetric?.ratio
    }

    private func statusBarTooltip(for entries: [StatusBarQuotaEntry]) -> String {
        guard !entries.isEmpty else {
            return appState.text.string(.statusBarNoData)
        }
        return entries
            .map { entry in
                appState.text.statusBarTooltip(
                    tool: entry.tool,
                    remainingPercent: entry.remainingPercent,
                    accountName: entry.accountName
                )
            }
            .joined(separator: "\n")
    }

    private func quotaLine(for metric: QuotaDisplayMetric?) -> StatusBarQuotaLine? {
        guard let ratio = metric?.ratio else { return nil }
        let percent = Int((min(max(ratio, 0), 1) * 100).rounded())
        return StatusBarQuotaLine(text: "\(percent)%", isZero: percent <= 0)
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
                guard let self, self.dashboardPanel.isVisible else { return }
                self.updateDashboardPanelSize()
                DispatchQueue.main.async { [weak self] in
                    self?.updateDashboardPanelSize()
                }
            }
            .store(in: &cancellables)
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
            pendingPanelPresentationTask = Task { [weak self] in
                guard let self else { return }
                appState.refreshLaunchAtLoginState()
                await appState.prepareSelectedToolForDashboardPresentation()
                guard !Task.isCancelled else { return }
                self.presentDashboardPanel(relativeTo: button)
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
        pendingPanelPresentationTask = nil
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

private struct StatusBarQuotaEntry {
    let tool: ToolKind
    let accountName: String
    let remainingPercent: Int
    let lines: [StatusBarQuotaLine]
}

private struct StatusBarQuotaLine {
    let text: String
    let isZero: Bool
}

@MainActor
private struct StatusBarQuotaDisplay {
    let items: [StatusBarQuotaEntry]

    var contentWidth: CGFloat {
        let itemWidths = items
            .map(StatusBarQuotaItemView.itemWidth(for:))
            .reduce(0, +)
        return ceil(
            StatusBarQuotaContentView.contentHorizontalInset * 2
                + StatusBarQuotaContentView.logoSize
                + StatusBarQuotaContentView.logoQuotaSpacing
                + itemWidths
        )
    }

    var preferredStatusItemLength: CGFloat {
        max(NSStatusItem.squareLength, contentWidth + 4)
    }
}

@MainActor
private final class StatusBarQuotaContentView: NSView {
    static let preferredHeight: CGFloat = 22
    static let contentHeight: CGFloat = 20
    static let contentHorizontalInset: CGFloat = 2
    static let logoSize: CGFloat = 17
    static let logoQuotaSpacing: CGFloat = 6

    private let logoImageView = NSImageView()
    private let stackView = NSStackView()
    private var currentDisplay: StatusBarQuotaDisplay?

    init(fallbackIcon: NSImage) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = false

        let iconCopy = fallbackIcon.copy() as? NSImage ?? fallbackIcon
        iconCopy.isTemplate = true
        logoImageView.image = iconCopy
        logoImageView.imageScaling = .scaleProportionallyDown
        logoImageView.contentTintColor = .labelColor
        logoImageView.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .gravityAreas
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(logoImageView)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            logoImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentHorizontalInset),
            logoImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: Self.logoSize),
            logoImageView.heightAnchor.constraint(equalToConstant: Self.logoSize),

            stackView.leadingAnchor.constraint(equalTo: logoImageView.trailingAnchor, constant: Self.logoQuotaSpacing),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentHorizontalInset),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        configure(display: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(display: StatusBarQuotaDisplay?) {
        currentDisplay = display
        logoImageView.contentTintColor = .labelColor

        guard let display else {
            removeQuotaItems()
            stackView.isHidden = true
            invalidateIntrinsicContentSize()
            return
        }

        removeQuotaItems()
        stackView.isHidden = false

        for item in display.items {
            stackView.addArrangedSubview(StatusBarQuotaItemView(item: item))
        }

        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: currentDisplay?.contentWidth ?? Self.logoSize + Self.contentHorizontalInset * 2,
            height: Self.preferredHeight
        )
    }

    private func removeQuotaItems() {
        for subview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
    }
}

@MainActor
private final class StatusBarQuotaItemView: NSView {
    static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 8.0, weight: .semibold)
    private static let toolIconSize: CGFloat = 14
    private static let iconTextSpacing: CGFloat = 3.5
    private static let lineHeight: CGFloat = 10
    private static let lineSpacing: CGFloat = 0
    private static let separatorWidth: CGFloat = 1
    private static let separatorLeading: CGFloat = 6
    private static let separatorTrailing: CGFloat = 6

    private let separatorView = NSView()
    private let toolLogoView: StatusBarToolLogoView
    private let labelStack = NSStackView()
    private let item: StatusBarQuotaEntry

    init(item: StatusBarQuotaEntry) {
        self.item = item
        self.toolLogoView = StatusBarToolLogoView(tool: item.tool, size: Self.toolIconSize)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.52).cgColor
        separatorView.translatesAutoresizingMaskIntoConstraints = false

        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = Self.lineSpacing
        labelStack.distribution = .fillEqually
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        for line in item.lines {
            let label = NSTextField(labelWithString: line.text)
            label.font = Self.lineFont
            label.textColor = line.isZero
                ? .systemRed
                : .labelColor
            label.alignment = .left
            label.lineBreakMode = .byClipping
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.heightAnchor.constraint(equalToConstant: Self.lineHeight).isActive = true
            labelStack.addArrangedSubview(label)
        }

        addSubview(separatorView)
        addSubview(toolLogoView)
        addSubview(labelStack)

        NSLayoutConstraint.activate([
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.separatorLeading),
            separatorView.centerYAnchor.constraint(equalTo: centerYAnchor),
            separatorView.widthAnchor.constraint(equalToConstant: Self.separatorWidth),
            separatorView.heightAnchor.constraint(equalToConstant: 12),

            toolLogoView.leadingAnchor.constraint(equalTo: separatorView.trailingAnchor, constant: Self.separatorTrailing),
            toolLogoView.centerYAnchor.constraint(equalTo: centerYAnchor),
            toolLogoView.widthAnchor.constraint(equalToConstant: Self.toolIconSize),
            toolLogoView.heightAnchor.constraint(equalToConstant: Self.toolIconSize),

            labelStack.leadingAnchor.constraint(equalTo: toolLogoView.trailingAnchor, constant: Self.iconTextSpacing),
            labelStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.itemWidth(for: item),
            height: StatusBarQuotaContentView.contentHeight
        )
    }

    static func itemWidth(for item: StatusBarQuotaEntry) -> CGFloat {
        let widest = item.lines
            .map { $0.text.size(withAttributes: [.font: lineFont]).width }
            .max() ?? 0
        return ceil(
            separatorLeading
                + separatorWidth
                + separatorTrailing
                + toolIconSize
                + iconTextSpacing
                + widest
        )
    }
}

@MainActor
private final class StatusBarToolLogoView: NSView {
    private let tool: ToolKind
    private let logoSize: CGFloat
    private let imageView = NSImageView()

    init(tool: ToolKind, size: CGFloat) {
        self.tool = tool
        self.logoSize = size
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: logoSize, height: logoSize)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateImage()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateImage()
    }

    private func updateImage() {
        imageView.image = StatusBarToolLogoImageCache.image(
            for: tool,
            size: logoSize,
            color: resolvedIconColor()
        )
    }

    private func resolvedIconColor() -> NSColor {
        let appearance = effectiveAppearance
        let fallback = Self.fallbackIconColor(for: appearance)
        var color = fallback
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? fallback
        }
        return color
    }

    private static func fallbackIconColor(for appearance: NSAppearance) -> NSColor {
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        return match == .darkAqua || match == .vibrantDark ? .white : .black
    }
}

@MainActor
enum StatusBarToolLogoImageCache {
    private static var tintedCache: [String: NSImage] = [:]

    static func image(for tool: ToolKind, size: CGFloat, color: NSColor) -> NSImage {
        let resolvedColor = color.usingColorSpace(.deviceRGB) ?? .labelColor
        let key = [
            tool.rawValue,
            String(format: "%.2f", size),
            String(format: "%.3f", resolvedColor.redComponent),
            String(format: "%.3f", resolvedColor.greenComponent),
            String(format: "%.3f", resolvedColor.blueComponent),
            String(format: "%.3f", resolvedColor.alphaComponent)
        ].joined(separator: "-")

        if let cached = tintedCache[key] {
            return cached
        }

        let sourceImage: NSImage
        if let url = AppResourceLocator.url(
            forResource: tool.logoResourceName,
            withExtension: "png",
            subdirectory: "Logos"
        ),
           let loaded = NSImage(contentsOf: url) {
            sourceImage = loaded
        } else {
            sourceImage = fallbackTemplateImage(for: tool)
        }

        let image = rasterizedIcon(from: sourceImage, size: size, color: resolvedColor)
        tintedCache[key] = image
        return image
    }

    private static func rasterizedIcon(from image: NSImage, size: CGFloat, color: NSColor) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff),
              let output = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: source.pixelsWide,
                pixelsHigh: source.pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else {
            let fallback = image.copy() as? NSImage ?? image
            fallback.size = NSSize(width: size, height: size)
            fallback.isTemplate = true
            return fallback
        }

        let resolvedColor = color.usingColorSpace(.deviceRGB) ?? .white
        let hasAlpha = source.hasAlpha
        for y in 0 ..< source.pixelsHigh {
            for x in 0 ..< source.pixelsWide {
                guard let color = source.colorAt(x: x, y: y),
                      let rgb = color.usingColorSpace(.deviceRGB) else {
                    output.setColor(.clear, atX: x, y: y)
                    continue
                }

                let alpha = hasAlpha
                    ? rgb.alphaComponent
                    : alphaFromLuminance(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                output.setColor(
                    NSColor(
                        deviceRed: resolvedColor.redComponent,
                        green: resolvedColor.greenComponent,
                        blue: resolvedColor.blueComponent,
                        alpha: alpha * resolvedColor.alphaComponent
                    ),
                    atX: x,
                    y: y
                )
            }
        }

        let rendered = NSImage(size: NSSize(width: size, height: size))
        rendered.addRepresentation(output)
        rendered.isTemplate = false
        return rendered
    }

    private static func alphaFromLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
        if luminance <= 0.08 { return 0 }
        if luminance >= 0.26 { return 1 }
        return (luminance - 0.08) / 0.18
    }

    private static func fallbackTemplateImage(for tool: ToolKind) -> NSImage {
        switch tool {
        case .codex:
            return Branding.makeBrandMarkIcon(size: 32, monochrome: true)
        case .cursor:
            return NSImage(systemSymbolName: "cube.fill", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil)
                ?? Branding.makeBrandMarkIcon(size: 32, monochrome: true)
        case .claudeCode:
            return NSImage(systemSymbolName: "asterisk", accessibilityDescription: nil)
                ?? Branding.makeBrandMarkIcon(size: 32, monochrome: true)
        }
    }

}
