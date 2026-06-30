import Foundation

extension CursorProvider {
    func readCursorStateValues(keys: [String], statePath: String) throws -> [String: String] {
        let immutableURI = sqliteImmutableURI(for: statePath)
        if let directValues = try? queryCursorStateDatabase(
            databasePath: immutableURI,
            keys: keys
        ), !directValues.isEmpty {
            return directValues
        }

        let snapshot = try makeCursorStateSnapshot(statePath: statePath)
        defer {
            try? fileService.removeItemIfExists(at: snapshot.directoryPath)
        }

        return try queryCursorStateDatabase(databasePath: snapshot.databasePath, keys: keys)
    }

    func queryCursorStateDatabase(databasePath: String, keys: [String]) throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let quotedKeys = keys
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ",")
        process.arguments = [
            "-readonly",
            "-batch",
            "-noheader",
            "-separator",
            "\t",
            databasePath,
            "SELECT key, value FROM ItemTable WHERE key IN (\(quotedKeys));"
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.network("读取 Cursor 登录状态失败\(message.map { "：\($0)" } ?? "")")
        }

        guard let output, !output.isEmpty else { return [:] }
        return output
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { result, line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return }
                result[String(parts[0])] = decodeCursorStateValue(String(parts[1]))
            }
    }

    func updateCursorStateDatabase(
        statePath: String,
        upserts: [String: String],
        deleteKeys: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-batch",
            fileService.expand(path: statePath)
        ]

        let script = cursorStateUpdateSQL(upserts: upserts, deleteKeys: deleteKeys)
        let inputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardError = errorPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(Data(script.utf8))
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.network("写入 Cursor 登录状态失败\(message.map { "：\($0)" } ?? "")")
        }
    }

    func cursorStateUpdateSQL(upserts: [String: String], deleteKeys: [String]) -> String {
        var statements = [
            "PRAGMA busy_timeout = 5000;",
            "BEGIN IMMEDIATE;"
        ]

        for (key, value) in upserts.sorted(by: { $0.key < $1.key }) {
            statements.append(
                "INSERT OR REPLACE INTO ItemTable(key, value) VALUES (\(sqlStringLiteral(key)), \(sqlStringLiteral(value)));"
            )
        }

        for key in deleteKeys.sorted() {
            guard upserts[key] == nil else { continue }
            statements.append("DELETE FROM ItemTable WHERE key = \(sqlStringLiteral(key));")
        }

        statements.append("COMMIT;")
        return statements.joined(separator: "\n") + "\n"
    }

    func sqlStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    func sqliteImmutableURI(for path: String) -> String {
        URL(fileURLWithPath: fileService.expand(path: path)).absoluteString + "?mode=ro&immutable=1"
    }

    func makeCursorStateSnapshot(statePath: String) throws -> CursorStateSnapshot {
        let expanded = fileService.expand(path: statePath)
        let sourceURL = URL(fileURLWithPath: expanded)
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-cursor-state-\(UUID().uuidString)", isDirectory: true)
        let snapshotDatabase = snapshotDirectory.appendingPathComponent(sourceURL.lastPathComponent)

        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: snapshotDatabase)
            try copyIfExists(from: URL(fileURLWithPath: expanded + "-wal"), to: URL(fileURLWithPath: snapshotDatabase.path + "-wal"))
            try copyIfExists(from: URL(fileURLWithPath: expanded + "-shm"), to: URL(fileURLWithPath: snapshotDatabase.path + "-shm"))
        } catch {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw ProviderError.network("读取 Cursor 登录状态失败：无法创建数据库快照（\(error.localizedDescription)）")
        }

        return CursorStateSnapshot(
            directoryPath: snapshotDirectory.path,
            databasePath: snapshotDatabase.path
        )
    }

    func copyIfExists(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func decodeCursorStateValue(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return raw
        }
        return decoded
    }
}
