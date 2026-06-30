import Foundation

struct FileService {
    func expand(path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: expand(path: path))
    }

    func directoryExists(at path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: expand(path: path), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    func readText(at path: String) throws -> String {
        let expanded = expand(path: path)
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ProviderError.missingFile(path: expanded)
        }
        return try String(contentsOfFile: expanded, encoding: .utf8)
    }

    func writeText(_ content: String, to path: String, permissions: Int? = nil) throws {
        let expanded = expand(path: path)
        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try applyPermissions(permissions, to: expanded)
    }

    func writeTextWithBackup(
        _ content: String,
        to path: String,
        backupBaseName: String? = nil,
        maxBackups: Int = 5,
        permissions: Int? = nil
    ) throws {
        let expanded = expand(path: path)
        let url = URL(fileURLWithPath: expanded)
        let data = Data(content.utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backupItemIfNeeded(
            at: expanded,
            newContents: data,
            backupBaseName: backupBaseName,
            maxBackups: maxBackups,
            backupPermissions: permissions
        )
        try data.write(to: url, options: .atomic)
        try applyPermissions(permissions, to: expanded)
    }

    func createDirectoryIfNeeded(at path: String) throws {
        let expanded = expand(path: path)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: expanded), withIntermediateDirectories: true)
    }

    func removeItemIfExists(at path: String) throws {
        let expanded = expand(path: path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: expanded))
    }

    func backupItemIfExists(
        at path: String,
        backupBaseName: String? = nil,
        maxBackups: Int = 5,
        permissions: Int? = nil
    ) throws {
        let expanded = expand(path: path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        try backupItemIfNeeded(
            at: expanded,
            newContents: nil,
            fallbackContents: data,
            backupBaseName: backupBaseName,
            maxBackups: maxBackups,
            backupPermissions: permissions
        )
    }

    func copyItemReplacing(from sourcePath: String, to targetPath: String) throws {
        let sourceExpanded = expand(path: sourcePath)
        let targetExpanded = expand(path: targetPath)

        guard FileManager.default.fileExists(atPath: sourceExpanded) else {
            throw ProviderError.missingFile(path: sourceExpanded)
        }

        try removeItemIfExists(at: targetExpanded)

        let targetURL = URL(fileURLWithPath: targetExpanded)
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: sourceExpanded), to: targetURL)
    }

    func copyItemReplacingWithBackup(
        from sourcePath: String,
        to targetPath: String,
        backupBaseName: String? = nil,
        maxBackups: Int = 5,
        targetPermissions: Int? = nil,
        backupPermissions: Int? = nil
    ) throws {
        let sourceExpanded = expand(path: sourcePath)
        let targetExpanded = expand(path: targetPath)

        guard FileManager.default.fileExists(atPath: sourceExpanded) else {
            throw ProviderError.missingFile(path: sourceExpanded)
        }

        let sourceURL = URL(fileURLWithPath: sourceExpanded)
        let targetURL = URL(fileURLWithPath: targetExpanded)
        let sourceData = try Data(contentsOf: sourceURL)
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backupItemIfNeeded(
            at: targetExpanded,
            newContents: sourceData,
            backupBaseName: backupBaseName,
            maxBackups: maxBackups,
            backupPermissions: backupPermissions
        )

        if FileManager.default.fileExists(atPath: targetExpanded) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try sourceData.write(to: targetURL, options: .atomic)
        try applyPermissions(targetPermissions, to: targetExpanded)
    }

    private func backupItemIfNeeded(
        at expandedPath: String,
        newContents: Data?,
        fallbackContents: Data? = nil,
        backupBaseName: String?,
        maxBackups: Int,
        backupPermissions: Int? = nil
    ) throws {
        let url = URL(fileURLWithPath: expandedPath)
        guard FileManager.default.fileExists(atPath: expandedPath) else { return }

        let currentContents = try Data(contentsOf: url)
        if let newContents, currentContents == newContents {
            return
        }

        let contentsToBackup = fallbackContents ?? currentContents
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedBaseName = backupBaseName ?? url.lastPathComponent
        let backupURL = try uniqueBackupURL(in: directory, baseName: resolvedBaseName)
        try contentsToBackup.write(to: backupURL, options: .atomic)
        try applyPermissions(backupPermissions, to: backupURL.path)
        try pruneBackups(in: directory, baseName: resolvedBaseName, maxBackups: maxBackups)
    }

    private func applyPermissions(_ permissions: Int?, to path: String) throws {
        guard let permissions else { return }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }

    private func uniqueBackupURL(in directory: URL, baseName: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let stem = "\(baseName).bak.\(formatter.string(from: Date()))"
        var attempt = 0
        while true {
            let filename = attempt == 0 ? stem : "\(stem).\(attempt)"
            let candidate = directory.appendingPathComponent(filename, isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private func pruneBackups(in directory: URL, baseName: String, maxBackups: Int) throws {
        guard maxBackups > 0 else { return }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let backups = entries
            .filter { $0.lastPathComponent.hasPrefix("\(baseName).bak.") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        for staleURL in backups.dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: staleURL)
        }
    }

}
