import AppKit

public enum QuotaBarApplication {
    @MainActor
    public static func run() -> Never {
        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        app.delegate = appDelegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        fatalError("NSApplicationMain returned unexpectedly")
    }
}
