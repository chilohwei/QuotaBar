import Foundation

extension CursorProvider {
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
