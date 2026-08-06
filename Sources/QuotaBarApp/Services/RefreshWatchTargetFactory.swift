import Foundation

struct RefreshWatchTargetFactory {
    private let environment: [String: String]
    private let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func watchTargets() -> [RefreshWatchTarget] {
        var targets: [RefreshWatchTarget] = [
            RefreshWatchTarget(url: AppPaths.claudeCodeStatusFile, reason: .claudeStatusLineChanged),
            RefreshWatchTarget(url: codexAuthURL(), reason: .credentialsChanged(.codex)),
            RefreshWatchTarget(url: claudeCodeAuthURL(), reason: .credentialsChanged(.claudeCode)),
            RefreshWatchTarget(url: claudeIdentityURL(), reason: .credentialsChanged(.claudeCode)),
            // Codex/Cursor keep quota server-side, so watch each tool's local activity file: when it
            // changes the user is using the tool and its quota may have moved — fetch fresh (throttled).
            RefreshWatchTarget(url: codexGlobalStateURL(), reason: .usageMayHaveChanged(.codex))
        ]

        for stateDatabaseURL in cursorStateDatabaseURLs() {
            targets.append(RefreshWatchTarget(url: stateDatabaseURL, reason: .credentialsChanged(.cursor)))
            targets.append(RefreshWatchTarget(url: stateDatabaseURL, reason: .usageMayHaveChanged(.cursor)))
        }

        return Array(Set(targets))
    }

    func codexGlobalStateURL() -> URL {
        let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw?.isEmpty == false ? raw! : "~/.codex"
        return URL(fileURLWithPath: (base as NSString).expandingTildeInPath)
            .appendingPathComponent(".codex-global-state.json")
    }

    func codexAuthURL() -> URL {
        let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw?.isEmpty == false ? raw! : "~/.codex"
        return URL(fileURLWithPath: (base as NSString).expandingTildeInPath)
            .appendingPathComponent("auth.json")
    }

    func claudeCodeAuthURL() -> URL {
        if let explicit = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json")
        }
        if let xdgConfig = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgConfig.isEmpty {
            return URL(fileURLWithPath: (xdgConfig as NSString).expandingTildeInPath)
                .appendingPathComponent("claude-code", isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        return homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("claude-code", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    func claudeIdentityURL() -> URL {
        homeDirectory.appendingPathComponent(".claude.json")
    }

    func cursorStateDatabaseURLs() -> [URL] {
        [
            "Cursor",
            "Cursor - Insiders",
            "Cursor Nightly"
        ].map { appName in
            homeDirectory.appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(appName, isDirectory: true)
                .appendingPathComponent("User", isDirectory: true)
                .appendingPathComponent("globalStorage", isDirectory: true)
                .appendingPathComponent("state.vscdb")
        }
    }
}
