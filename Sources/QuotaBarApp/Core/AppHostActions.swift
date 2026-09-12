import Foundation

/// Side effects the app host (the status bar controller / app delegate) performs on behalf of
/// `AppState`. These are UI- or process-level actions `AppState` cannot do itself — driving the
/// update flow, toggling launch-at-login, closing the dashboard, restarting a tool, presenting a
/// restart prompt.
///
/// Bundling them into one explicit contract keeps the host/state boundary visible instead of
/// scattering eight optional closures across `AppState`. Every field is optional because the host
/// wires them up incrementally during launch; call sites use optional-chaining so an unwired
/// action is a no-op.
@MainActor
struct AppHostActions {
    var checkForUpdates: (() -> Void)?
    var installAvailableUpdate: (() -> Void)?
    var ignoreAvailableUpdate: (() -> Void)?
    var isLaunchAtLoginEnabled: (() -> Bool)?
    var setLaunchAtLoginEnabled: ((Bool) -> Void)?
    var closeDashboard: (() -> Void)?
    var restartTool: ((ToolKind) -> Void)?
    var presentRestartPrompt: ((ToolKind, String) -> Void)?
}
