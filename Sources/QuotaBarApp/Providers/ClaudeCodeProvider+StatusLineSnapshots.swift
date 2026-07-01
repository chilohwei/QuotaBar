import Foundation

extension ClaudeCodeProvider {
    func loadStatusLineSnapshot() throws -> StatusLineSnapshotLoad? {
        let url = AppPaths.claudeCodeStatusFile
        let path = url.path
        guard fileService.fileExists(at: path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let status = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let capturedAt = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            ?? Date()
        return StatusLineSnapshotLoad(status: status, capturedAt: capturedAt)
    }

    func makeWindow(
        status: [String: Any]?,
        key: String,
        label: String,
        now: Date = Date(),
        rejectExpiredWindows: Bool = true
    ) -> QuotaWindow? {
        guard let rateLimits = status?["rate_limits"] as? [String: Any],
              let window = rateLimits[key] as? [String: Any],
              let usedPercentage = number(window["used_percentage"]) else {
            return nil
        }
        let resetAt = parseFlexibleDate(firstValue(
            in: window,
            keys: ["resets_at", "reset_at", "resetAt", "next_reset_at", "nextResetAt"]
        ))
        // The statusLine snapshot is only a fallback for when live `/usage` is unavailable, and
        // Claude Code freezes its `rate_limits` between API calls. Once a window's reset time has
        // passed, its stored `used_percentage` is untrustworthy: it may mean the window reset and
        // is now idle at 0%, OR that this frozen snapshot is simply stale while real usage kept
        // climbing elsewhere (e.g. a managed/remote session that never feeds this local hook — in
        // which case the true figure can be far from 0). We cannot distinguish the two, so we drop
        // the window rather than fabricate a number. The accompanying note explains the gap, and
        // live `/usage` remains the source of truth for an accurate current figure.
        if rejectExpiredWindows, let resetAt, resetAt.addingTimeInterval(60) < now {
            return nil
        }
        return QuotaWindow(
            label: label,
            used: min(max(usedPercentage, 0), 100),
            limit: 100,
            resetAt: resetAt
        )
    }

    func loadActiveRateLimitEvent(status: [String: Any]?, now: Date) -> ClaudeRateLimitEvent? {
        transcriptURLs(status: status, now: now)
            .compactMap { latestRateLimitEvent(in: $0, now: now) }
            .filter { activeRateLimit(from: $0, fallbackResetAt: nil, now: now) != nil }
            .sorted { $0.capturedAt > $1.capturedAt }
            .first
    }

    func latestRateLimitEvent(in url: URL, now: Date) -> ClaudeRateLimitEvent? {
        guard let text = readTailText(from: url, byteLimit: Self.transcriptTailByteLimit) else {
            return nil
        }

        let fileModifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var latest: ClaudeRateLimitEvent?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let event = parseRateLimitEvent(
                jsonLine: String(rawLine),
                fileModifiedAt: fileModifiedAt,
                now: now
            ),
                  activeRateLimit(from: event, fallbackResetAt: nil, now: now) != nil else {
                continue
            }
            if latest == nil || event.capturedAt > latest!.capturedAt {
                latest = event
            }
        }
        return latest
    }

    func transcriptURLs(status: [String: Any]?, now: Date) -> [URL] {
        var urls: [URL] = []
        if let transcriptPath = firstString(
            in: status as Any,
            keys: ["transcript_path", "transcriptPath", "transcript"]
        ) {
            urls.append(URL(fileURLWithPath: fileService.expand(path: transcriptPath)))
        }

        urls.append(contentsOf: recentClaudeProjectTranscriptURLs(now: now))

        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted
        }
    }

    func recentClaudeProjectTranscriptURLs(now: Date) -> [URL] {
        let projectsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modifiedAt) <= Self.rateLimitTranscriptLookback else { continue }
            entries.append((url, modifiedAt))
        }

        return Array(
            entries
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(Self.recentTranscriptFileLimit)
                .map(\.url)
        )
    }

    func readTailText(from url: URL, byteLimit: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            let fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: fileSize > byteLimit ? fileSize - byteLimit : 0)
            guard let data = try handle.readToEnd(), !data.isEmpty else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    func parseRateLimitEvent(
        jsonLine: String,
        fileModifiedAt: Date?,
        now: Date
    ) -> ClaudeRateLimitEvent? {
        let trimmed = jsonLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("429")
            || trimmed.localizedCaseInsensitiveContains("rate_limit")
            || trimmed.localizedCaseInsensitiveContains("usage limit")
            || trimmed.localizedCaseInsensitiveContains("session limit") else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return parseRateLimitEvent(object: object, fileModifiedAt: fileModifiedAt, now: now)
    }

    func parseRateLimitEvent(
        object: Any,
        fileModifiedAt: Date?,
        now: Date
    ) -> ClaudeRateLimitEvent? {
        guard let dict = object as? [String: Any] else { return nil }

        // A genuine Claude Code rate-limit record carries these markers at the TOP LEVEL of the
        // transcript entry. The earlier heuristic also matched on free text ("usage limit" /
        // "session limit" + "reset") found anywhere in the line, which misfired on any transcript
        // that merely *mentions* a limit — tool output, assistant discussion, even this debugging
        // session — forcing a false "blocked". Read the structural fields directly (not a
        // recursive search, which could pick up such strings nested inside content).
        let isApiErrorMessage = (dict["isApiErrorMessage"] as? Bool) == true
        let statusCode = number(dict["apiErrorStatus"])
        let errorCode = (dict["error"] as? String)?.lowercased()
        let isRateLimit = isApiErrorMessage
            && (Int(statusCode ?? -1) == 429 || errorCode == "rate_limit")
        guard isRateLimit else { return nil }

        var strings: [String] = []
        collectStrings(in: dict, into: &strings)
        let joinedText = strings.joined(separator: " ")

        let capturedAt = parseFlexibleDate(findValue(in: dict, keys: ["timestamp", "createdAt", "created_at"]))
            ?? fileModifiedAt
            ?? now
        let resetAt = parseFlexibleDate(findValue(
            in: dict,
            keys: ["resets_at", "reset_at", "resetAt", "retryAt", "retry_at"]
        )) ?? parseRateLimitResetDate(in: joinedText, referenceDate: capturedAt)
        let message = strings.first { value in
            let lower = value.lowercased()
            return lower.contains("limit") && lower.contains("reset")
        }

        return ClaudeRateLimitEvent(resetAt: resetAt, capturedAt: capturedAt, message: message)
    }

    func activeRateLimit(
        from event: ClaudeRateLimitEvent?,
        fallbackResetAt: Date?,
        now: Date
    ) -> ActiveRateLimit? {
        guard let event else { return nil }
        if let resetAt = event.resetAt ?? fallbackResetAt {
            return resetAt.addingTimeInterval(60) > now ? ActiveRateLimit(resetAt: resetAt) : nil
        }
        return now.timeIntervalSince(event.capturedAt) <= Self.rateLimitWithoutResetFreshness
            ? ActiveRateLimit(resetAt: nil)
            : nil
    }

    func parseOAuthUsageWindow(_ dict: [String: Any]?, label: String) -> QuotaWindow? {
        guard let dict else { return nil }
        guard let used = number(dict["utilization"]) ?? number(dict["used_percentage"]) else {
            return nil
        }
        let resetAt = parseFlexibleDate(dict["resets_at"] ?? dict["reset_at"] ?? dict["resetAt"])
        return QuotaWindow(
            label: label,
            used: min(max(used, 0), 100),
            limit: 100,
            resetAt: resetAt
        )
    }

}
