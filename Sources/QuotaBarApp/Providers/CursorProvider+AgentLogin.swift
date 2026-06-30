import Foundation

extension CursorProvider {
    func openCursorLoginPage() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["https://cursor.com/login"]
        try process.run()
    }

    func cursorAgentExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/cursor-agent",
            "\(home)/.local/bin/agent",
            "/opt/homebrew/bin/cursor-agent",
            "/opt/homebrew/bin/agent",
            "/usr/local/bin/cursor-agent",
            "/usr/local/bin/agent"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func runCursorAgentLogin(agentURL: URL, timeout: TimeInterval) async throws {
        let process = Process()
        process.executableURL = agentURL
        process.arguments = ["login"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)

        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                throw ProviderError.unsupported("Cursor Agent 登录超时，请完成浏览器登录后重试")
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        guard process.terminationStatus == 0 else {
            let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let outputText = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = [errorText, outputText]
                .compactMap { text in
                    guard let text, !text.isEmpty else { return nil }
                    return text
                }
                .joined(separator: "\n")
            throw ProviderError.unsupported(message.isEmpty ? "Cursor Agent 登录失败" : "Cursor Agent 登录失败：\(message)")
        }
    }

    func readKeychainPassword(service: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cursorAgentEmail() -> String? {
        guard let agentURL = cursorAgentExecutableURL() else { return nil }
        let process = Process()
        process.executableURL = agentURL
        process.arguments = ["status"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }

        let pattern = #"(?i)logged in as\s+([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[range]).lowercased()
    }
}
