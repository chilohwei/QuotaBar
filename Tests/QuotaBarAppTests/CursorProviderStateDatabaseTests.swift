import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Cursor provider state database")
struct CursorProviderStateDatabaseTests {
    @Test("read-only state query sees auth values still held in WAL")
    func readOnlyStateQuerySeesAuthValuesStillHeldInWAL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBar Cursor State Tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = directory.appendingPathComponent("state.vscdb")
        try runSQLite(database.path, script: """
        PRAGMA journal_mode=WAL;
        CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO ItemTable VALUES('cursorAuth/stripeMembershipType', 'free');
        PRAGMA wal_checkpoint(TRUNCATE);
        """)

        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        reader.arguments = [database.path]
        let readerInput = Pipe()
        let readerOutput = Pipe()
        reader.standardInput = readerInput
        reader.standardOutput = readerOutput
        reader.standardError = Pipe()
        try reader.run()
        defer {
            try? readerInput.fileHandleForWriting.write(contentsOf: Data("COMMIT;\n.quit\n".utf8))
            try? readerInput.fileHandleForWriting.close()
            reader.waitUntilExit()
        }

        try readerInput.fileHandleForWriting.write(contentsOf: Data("""
        BEGIN;
        SELECT value FROM ItemTable WHERE key = 'cursorAuth/stripeMembershipType';

        """.utf8))
        let initialRead = String(data: readerOutput.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        #expect(initialRead.contains("free"))

        try runSQLite(database.path, script: """
        PRAGMA journal_mode=WAL;
        PRAGMA wal_autocheckpoint=0;
        INSERT OR REPLACE INTO ItemTable VALUES('cursorAuth/accessToken', 'wal-access-token');
        INSERT OR REPLACE INTO ItemTable VALUES('cursorAuth/refreshToken', 'wal-refresh-token');
        INSERT OR REPLACE INTO ItemTable VALUES('cursorAuth/cachedEmail', 'wal@example.com');
        """)

        let walPath = database.path + "-wal"
        let walSize = try #require(FileManager.default.attributesOfItem(atPath: walPath)[.size] as? NSNumber)
        #expect(walSize.intValue > 0)

        let values = try CursorProvider().readCursorStateValues(
            keys: [
                "cursorAuth/accessToken",
                "cursorAuth/refreshToken",
                "cursorAuth/cachedEmail",
                "cursorAuth/stripeMembershipType"
            ],
            statePath: database.path
        )

        #expect(values["cursorAuth/accessToken"] == "wal-access-token")
        #expect(values["cursorAuth/refreshToken"] == "wal-refresh-token")
        #expect(values["cursorAuth/cachedEmail"] == "wal@example.com")
        #expect(values["cursorAuth/stripeMembershipType"] == "free")
    }

    private func runSQLite(_ databasePath: String, script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databasePath]
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        _ = output.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ProviderError.network("sqlite test setup failed: \(message)")
        }
    }
}
