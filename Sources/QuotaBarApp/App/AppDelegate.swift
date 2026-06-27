import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusBarController: StatusBarController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = Branding.makeAppIcon()
        appState.bootstrap()
        statusBarController = StatusBarController(appState: appState)

        Publishers.CombineLatest4(
            appState.$quotaByAccount,
            appState.$selectedTool,
            appState.$activeAccountByTool,
            appState.$language
        )
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.statusBarController?.updateStatusTitle()
            }
            .store(in: &cancellables)

        appState.$accounts
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.statusBarController?.updateStatusTitle()
            }
            .store(in: &cancellables)

        appState.$menuBarVisibleTools
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.statusBarController?.updateStatusTitle()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        statusBarController?.shutdown()
        appState.shutdown()
    }

}
