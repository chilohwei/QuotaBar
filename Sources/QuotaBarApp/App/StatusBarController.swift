import AppKit
import Combine
import SwiftUI

final class DashboardPanel: NSPanel {
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

    // Fallback when SwiftUI does not consume Esc (e.g. focus outside the hosting view).
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    let statusItem: NSStatusItem
    let dashboardPanel: DashboardPanel
    var globalEventMonitor: Any?
    var localEventMonitor: Any?
    var applicationResignObserver: NSObjectProtocol?
    let appState: AppState
    let updateService = UpdateService()
    let launchAtLoginService = LaunchAtLoginService()
    var isCheckingForUpdates = false
    var isInstallingUpdate = false
    var availableRelease: UpdateRelease?
    var updateProgressWindow: NSWindow?
    var updateProgressIndicator: NSProgressIndicator?
    var updateProgressTitleLabel: NSTextField?
    var updateProgressDetailLabel: NSTextField?
    var pendingPanelPresentationTask: Task<Void, Never>?
    private var statusBarContentView: StatusBarQuotaContentView?
    private var isStatusTitleUpdateScheduled = false
    var isPresentingRestartPrompt = false
    var cancellables = Set<AnyCancellable>()

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
            },
            ignoreAvailableUpdate: { [weak self] in
                Task { @MainActor in
                    self?.ignoreAvailableUpdateFromDashboard()
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
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let applicationResignObserver {
            NotificationCenter.default.removeObserver(applicationResignObserver)
            self.applicationResignObserver = nil
        }
        pendingPanelPresentationTask?.cancel()
        pendingPanelPresentationTask = nil
        dashboardPanel.close()
    }

    func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        let inputs = ToolKind.allCases.compactMap { tool -> StatusBarQuotaInput? in
            guard appState.isToolVisibleInMenuBar(tool),
                  let active = appState.activeAccount(for: tool) else {
                return nil
            }
            let quota = appState.quotaByAccount[active.id]
            return StatusBarQuotaInput(
                tool: tool,
                accountName: active.name,
                quota: quota,
                alternativeAccountName: quota.flatMap {
                    alternativeAccountName(for: tool, active: active, quota: $0)
                }
            )
        }
        let entries = StatusBarQuotaPresenter.entries(for: inputs)
        let display = entries.isEmpty ? nil : StatusBarQuotaDisplay(items: entries)

        button.toolTip = StatusBarQuotaPresenter.tooltip(for: entries, text: appState.text)
        button.contentTintColor = nil
        statusBarContentView?.configure(display: display)
        statusItem.length = display?.preferredStatusItemLength ?? NSStatusItem.squareLength
        button.setAccessibilityLabel(button.toolTip ?? appState.text.string(.statusBarNoData))
    }

    // Names a ready-to-use recommended account when the active one is out of quota,
    // so the menu bar can hint that switching would help.
    private func alternativeAccountName(for tool: ToolKind, active: Account, quota: QuotaSnapshot) -> String? {
        let exhausted = quota.hasExhaustedQuota || (quota.statusBarMetric?.ratio ?? 1) <= 0.001
        guard exhausted,
              let recommended = appState.recommendedAccount(for: tool),
              recommended.id != active.id else {
            return nil
        }
        return recommended.name
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        applyMenuBarIcon(to: button)
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        updateStatusTitle()
    }

    func scheduleStatusTitleUpdate() {
        guard !isStatusTitleUpdateScheduled else { return }
        isStatusTitleUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isStatusTitleUpdateScheduled = false
            self.updateStatusTitle()
        }
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

}
