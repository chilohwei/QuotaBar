import Foundation

extension ClaudeCodeProvider {
    struct StatusLineInstallPaths {
        let claudeDirectory: URL
        let wrapperURL: URL
        let originalURL: URL
        let settingsURL: URL
    }

    var quotaBarStatusLineCommand: String {
        "~/.claude/quotabar-statusline.zsh"
    }

    func statusLineInstallPaths() -> StatusLineInstallPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        return StatusLineInstallPaths(
            claudeDirectory: claudeDirectory,
            wrapperURL: claudeDirectory.appendingPathComponent("quotabar-statusline.zsh"),
            originalURL: claudeDirectory.appendingPathComponent("quotabar-statusline-original.json"),
            settingsURL: claudeDirectory.appendingPathComponent("settings.json")
        )
    }

    func quotaBarStatusLineIsInstalled(settingsJSON: String?) -> Bool {
        guard let settingsJSON,
              let data = settingsJSON.data(using: .utf8),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = settings["statusLine"] as? [String: Any],
              statusLine["command"] as? String == quotaBarStatusLineCommand else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: statusLineInstallPaths().wrapperURL.path)
    }

    func installQuotaBarStatusLine() throws {
        let paths = statusLineInstallPaths()

        try FileManager.default.createDirectory(at: paths.claudeDirectory, withIntermediateDirectories: true)
        try writeStatusLineWrapper(to: paths.wrapperURL, originalURL: paths.originalURL)

        var settings = try loadSettings(from: paths.settingsURL)
        let currentStatusLine = settings["statusLine"] as? [String: Any]
        let currentCommand = currentStatusLine?["command"] as? String
        if currentCommand != quotaBarStatusLineCommand {
            try writeJSONObjectIfChanged(currentStatusLine ?? [:], to: paths.originalURL)
        }

        var nextStatusLine = currentStatusLine ?? [:]
        nextStatusLine["type"] = "command"
        nextStatusLine["command"] = quotaBarStatusLineCommand
        nextStatusLine["refreshInterval"] = nextStatusLine["refreshInterval"] ?? 30
        settings["statusLine"] = nextStatusLine
        try writeJSONObjectIfChanged(settings, to: paths.settingsURL)
    }

    func loadSettings(from url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return settings
    }

    func writeJSONObjectIfChanged(_ object: Any, to url: URL) throws {
        let canonicalData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if let currentData = try? Data(contentsOf: url),
           let currentObject = try? JSONSerialization.jsonObject(with: currentData),
           let currentCanonicalData = try? JSONSerialization.data(withJSONObject: currentObject, options: [.sortedKeys]),
           currentCanonicalData == canonicalData {
            return
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func writeStatusLineWrapper(to url: URL, originalURL: URL) throws {
        let snapshotPath = AppPaths.claudeCodeStatusFile.path
        let script = """
        #!/bin/zsh
        set -u

        INPUT="$(cat)"
        SNAPSHOT=\(shellQuoted(snapshotPath))
        ORIGINAL=\(shellQuoted(originalURL.path))

        mkdir -p "$(dirname "$SNAPSHOT")"
        TMP_FILE="${SNAPSHOT}.$$"
        printf '%s' "$INPUT" > "$TMP_FILE" && mv "$TMP_FILE" "$SNAPSHOT"

        ORIG_COMMAND="$(/usr/bin/python3 - "$ORIGINAL" <<'PY'
        import json
        import sys
        try:
            with open(sys.argv[1], "r", encoding="utf-8") as f:
                data = json.load(f)
            command = data.get("command") if isinstance(data, dict) else None
            print(command or "")
        except Exception:
            print("")
        PY
        )"

        if [[ -n "$ORIG_COMMAND" ]]; then
            printf '%s' "$INPUT" | /bin/zsh -lc "$ORIG_COMMAND"
            exit $?
        fi

        /usr/bin/python3 - "$SNAPSHOT" <<'PY'
        import json
        import sys
        try:
            with open(sys.argv[1], "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            print("Claude Code")
            raise SystemExit(0)

        model = (((data.get("model") or {}).get("display_name")) or "Claude").strip()
        limits = data.get("rate_limits") or {}
        parts = []
        windows = (
            (("five_hour", "fiveHour", "five_hour_limit", "fiveHourLimit", "5h"), "5h"),
            (("seven_day", "sevenDay", "weekly", "weekly_all_models", "weeklyAllModels", "7d"), "7d"),
        )
        for keys, label in windows:
            window = next((limits.get(key) for key in keys if isinstance(limits.get(key), dict)), {})
            value = window.get("used_percentage")
            if isinstance(value, (int, float)):
                parts.append(f"{label}: {value:.0f}%")
        print(f"[{model}] " + " ".join(parts) if parts else f"[{model}]")
        PY
        """

        try writeTextIfChanged(script, to: url)
        try setPosixPermissionsIfNeeded(0o700, for: url)
    }

    func writeTextIfChanged(_ text: String, to url: URL) throws {
        if let current = try? String(contentsOf: url, encoding: .utf8),
           current == text {
            return
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func setPosixPermissionsIfNeeded(_ permissions: Int, for url: URL) throws {
        let current = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        if current?.intValue == permissions {
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum OAuthUsageFetchError: Error, Equatable {
    case unauthorized
    case rateLimited(retryAfter: Date?)
    case invalidResponse
    case httpStatus(Int)
}
