import AppKit
import Combine
import SwiftUI

extension StatusBarController {
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
        alert.addButton(withTitle: appState.text.string(.ignore))
        alert.addButton(withTitle: appState.text.string(.cancel))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            performUpdateInstall(release)
        case .alertSecondButtonReturn:
            ignoreUpdate(release)
        default:
            break
        }
    }

    private func showUpdateError(_ error: Error) {
        showInformationalAlert(
            title: appState.text.string(.updateCheckFailedTitle),
            message: appState.text.updateCheckFailedMessage(resolvedErrorMessage(error))
        )
    }

    func showInformationalAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: appState.text.string(.ok))
        alert.runModal()
    }

    func resolvedErrorMessage(_ error: Error) -> String {
        appState.text.userFacingErrorMessage(error)
    }

    func performUpdateCheck(showFeedback: Bool) {
        guard !isCheckingForUpdates, !isInstallingUpdate else { return }
        isCheckingForUpdates = true
        // Silent startup checks stay invisible; the banner only appears when the
        // user asked for a check or an update is actually available.
        if showFeedback {
            appState.updateBannerState = .checking
        }
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
                            if AppPreferencesStore.isUpdateVersionIgnored(release.version) {
                                self.availableRelease = nil
                                self.appState.updateBannerState = .idle
                            } else {
                                self.availableRelease = release
                                self.appState.updateBannerState = .available(version: release.version)
                            }
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

    func installAvailableUpdateFromDashboard() {
        guard !isInstallingUpdate else { return }
        if let release = availableRelease {
            performUpdateInstall(release)
        } else {
            performUpdateCheck(showFeedback: true)
        }
    }

    func ignoreAvailableUpdateFromDashboard() {
        guard let release = availableRelease else {
            appState.updateBannerState = .idle
            return
        }
        ignoreUpdate(release)
    }

    private func ignoreUpdate(_ release: UpdateRelease) {
        AppPreferencesStore.setIgnoredUpdateVersion(release.version)
        availableRelease = nil
        appState.updateBannerState = .idle
        AppLog.update.info("Ignored update version \(release.version, privacy: .public)")
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

// @unchecked Sendable: its only stored property is a weak controller reference set at init and
// read solely inside a `@MainActor` hop, so there is no cross-thread mutable state.
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
