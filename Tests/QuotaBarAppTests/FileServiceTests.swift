import Foundation
import Testing
@testable import QuotaBarApp

@Suite("File service")
struct FileServiceTests {
    @Test("writeText applies requested private permissions")
    func writeTextAppliesPrivatePermissions() throws {
        let fixture = try FileServiceFixture()
        defer { fixture.cleanup() }

        let path = fixture.url.appendingPathComponent("nested/secret.txt").path
        try fixture.service.writeText("secret", to: path, permissions: 0o600)

        #expect(try fixture.permissions(at: path) == 0o600)
    }

    @Test("writeTextWithBackup applies private permissions to target and backup")
    func writeTextWithBackupAppliesPrivatePermissions() throws {
        let fixture = try FileServiceFixture()
        defer { fixture.cleanup() }

        let path = fixture.url.appendingPathComponent("auth.json").path
        try fixture.service.writeText("old-token", to: path, permissions: 0o644)
        try fixture.service.writeTextWithBackup(
            "new-token",
            to: path,
            backupBaseName: "auth.json",
            permissions: 0o600
        )

        let backupPath = try fixture.singleBackupPath(baseName: "auth.json")
        #expect(try String(contentsOfFile: backupPath, encoding: .utf8) == "old-token")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "new-token")
        #expect(try fixture.permissions(at: path) == 0o600)
        #expect(try fixture.permissions(at: backupPath) == 0o600)
    }

    @Test("backupItemIfExists applies requested private permissions")
    func backupItemIfExistsAppliesPrivatePermissions() throws {
        let fixture = try FileServiceFixture()
        defer { fixture.cleanup() }

        let path = fixture.url.appendingPathComponent("registry.auth.json").path
        try fixture.service.writeText("token", to: path, permissions: 0o644)
        try fixture.service.backupItemIfExists(
            at: path,
            backupBaseName: "registry.auth.json",
            permissions: 0o600
        )

        let backupPath = try fixture.singleBackupPath(baseName: "registry.auth.json")
        #expect(try String(contentsOfFile: backupPath, encoding: .utf8) == "token")
        #expect(try fixture.permissions(at: backupPath) == 0o600)
    }

    @Test("copyItemReplacingWithBackup applies private permissions")
    func copyItemReplacingWithBackupAppliesPrivatePermissions() throws {
        let fixture = try FileServiceFixture()
        defer { fixture.cleanup() }

        let sourcePath = fixture.url.appendingPathComponent("source.txt").path
        let targetPath = fixture.url.appendingPathComponent("target.txt").path
        try fixture.service.writeText("new", to: sourcePath)
        try fixture.service.writeText("old", to: targetPath, permissions: 0o644)
        try fixture.service.copyItemReplacingWithBackup(
            from: sourcePath,
            to: targetPath,
            backupBaseName: "target.txt",
            targetPermissions: 0o600,
            backupPermissions: 0o600
        )

        let backupPath = try fixture.singleBackupPath(baseName: "target.txt")
        #expect(try String(contentsOfFile: targetPath, encoding: .utf8) == "new")
        #expect(try String(contentsOfFile: backupPath, encoding: .utf8) == "old")
        #expect(try fixture.permissions(at: targetPath) == 0o600)
        #expect(try fixture.permissions(at: backupPath) == 0o600)
    }

    @Test("app private directories use owner-only permissions")
    func appPrivateDirectoriesUseOwnerOnlyPermissions() throws {
        let fixture = try FileServiceFixture()
        defer { fixture.cleanup() }

        let directory = fixture.url.appendingPathComponent("QuotaBar", isDirectory: true)
        try AppPaths.ensurePrivateDirectory(directory)

        #expect(try fixture.permissions(at: directory.path) == 0o700)
    }
}

private struct FileServiceFixture {
    let service = FileService()
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarFileServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func permissions(at path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

    func singleBackupPath(baseName: String) throws -> String {
        let backups = try FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(baseName).bak.") }
        let backup = try #require(backups.singleElement)
        return backup.path
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

private extension Array {
    var singleElement: Element? {
        count == 1 ? first : nil
    }
}
