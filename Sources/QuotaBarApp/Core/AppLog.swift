import Foundation
import OSLog

enum AppLog {
    private static var subsystem: String {
        Bundle.main.bundleIdentifier ?? "com.chiloh.QuotaBar"
    }

    static let app = Logger(subsystem: subsystem, category: "App")
    static let account = Logger(subsystem: subsystem, category: "Account")
    static let refresh = Logger(subsystem: subsystem, category: "Refresh")
    static let update = Logger(subsystem: subsystem, category: "Update")
}
