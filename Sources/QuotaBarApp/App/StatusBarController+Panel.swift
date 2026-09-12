import AppKit
import Combine
import SwiftUI

extension StatusBarController {
    func configureDashboardPanel() {
        let host = NSHostingController(
            rootView: DashboardView(appState: appState)
                .frame(width: DashboardLayout.panelWidth, height: DashboardLayout.preferredPanelHeight)
                .clipShape(RoundedRectangle(cornerRadius: DashboardLayout.panelCornerRadius, style: .continuous))
        )
        host.view.frame = NSRect(origin: .zero, size: DashboardLayout.panelSize)
        host.preferredContentSize = DashboardLayout.panelSize
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = DashboardLayout.panelCornerRadius
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

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.dismissDashboardPanelIfAllowed()
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleLocalMouseDown(event)
            }
            return event
        }
        applicationResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismissDashboardPanelIfAllowed()
            }
        }

        appState.registerDashboardCloseAction { [weak self] in
            guard let self, self.dashboardPanel.isVisible else { return }
            self.dashboardPanel.close()
        }

        appState.registerToolRestartAction { [weak self] tool in
            self?.restartToolApp(tool)
        }

        appState.registerRestartPromptPresenter { [weak self] tool, message in
            // Deferred so the caller's task keeps running while the modal alert is up.
            Task { @MainActor in
                self?.presentRestartPrompt(tool: tool, message: message)
            }
        }

        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.scheduleStatusTitleUpdate() }
            .store(in: &cancellables)

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

    private func handleLocalMouseDown(_ event: NSEvent) {
        let eventWindow = event.window
        guard eventWindow !== statusItem.button?.window,
              !isDashboardOwnedWindow(eventWindow) else {
            return
        }
        dismissDashboardPanelIfAllowed()
    }

    private func isDashboardOwnedWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window === dashboardPanel || window.sheetParent === dashboardPanel {
            return true
        }
        return dashboardPanel.childWindows?.contains(where: { $0 === window }) == true
    }

    private func dismissDashboardPanelIfAllowed() {
        guard dashboardPanel.isVisible,
              !isPresentingRestartPrompt else {
            return
        }
        dashboardPanel.close()
    }

    @objc func handleStatusItemClick(_ sender: AnyObject?) {
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
            // An unanswered restart sheet is attached to the panel; leave both up.
            guard !isPresentingRestartPrompt else { return }
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
        // If the panel goes down with a sheet still attached, the sheet's completion never
        // fires; clear the flag so outside-click closing isn't disabled forever.
        isPresentingRestartPrompt = false
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
}
