import Foundation

enum AppPaths {
    private static let appSupportFolderName = "QuotaBar"
    private static let legacyAppSupportFolderNames = ["CodeBuddy", "DevRadar"]

    static let appSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base.appendingPathComponent(appSupportFolderName, isDirectory: true)
    }()

    static let accountsFile = appSupportDirectory.appendingPathComponent("accounts.json")
    static let secretsFile = appSupportDirectory.appendingPathComponent("secrets.json")
    static let quotaCacheDirectory = appSupportDirectory.appendingPathComponent("quota-cache", isDirectory: true)
    static let claudeCodeStatusFile = appSupportDirectory.appendingPathComponent("claude-code-status.json")
    static let accountQuotaSnapshotsDirectory = quotaCacheDirectory.appendingPathComponent("accounts", isDirectory: true)
    static let managedProfilesDirectory = appSupportDirectory.appendingPathComponent("profiles", isDirectory: true)
    static let managedCodexHomesDirectory = managedProfilesDirectory.appendingPathComponent("codex", isDirectory: true)
    static let managedCursorProfilesDirectory = managedProfilesDirectory.appendingPathComponent("cursor", isDirectory: true)

    static func managedCodexHomePath(accountID: UUID) -> String {
        managedCodexHomesDirectory.appendingPathComponent(accountID.uuidString, isDirectory: true).path
    }

    static func managedCursorProfilePath(accountID: UUID) -> String {
        managedCursorProfilesDirectory.appendingPathComponent(accountID.uuidString, isDirectory: true).path
    }

    static func ensureDirectories() throws {
        try migrateLegacyAppSupportIfNeeded()
        try ensurePrivateDirectory(appSupportDirectory)
        try ensurePrivateDirectory(quotaCacheDirectory)
        try ensurePrivateDirectory(accountQuotaSnapshotsDirectory)
        try ensurePrivateDirectory(managedProfilesDirectory)
        try ensurePrivateDirectory(managedCodexHomesDirectory)
        try ensurePrivateDirectory(managedCursorProfilesDirectory)
    }

    static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func migrateLegacyAppSupportIfNeeded() throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: appSupportDirectory.path) else { return }

        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        for legacyName in legacyAppSupportFolderNames {
            let legacyPath = base.appendingPathComponent(legacyName, isDirectory: true)
            guard fileManager.fileExists(atPath: legacyPath.path) else { continue }
            try fileManager.moveItem(at: legacyPath, to: appSupportDirectory)
            return
        }
    }
}
