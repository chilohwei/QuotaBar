import Foundation
import Testing

@Suite("Background credential policy")
struct BackgroundCredentialPolicyTests {
    @Test("automatic credential paths never invoke interactive system APIs")
    func automaticCredentialPathsNeverInvokeInteractiveSystemAPIs() throws {
        let sourcesRoot = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("QuotaBarApp", isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: nil
            )
        )
        let allSwiftSources = try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        #expect(!allSwiftSources.isEmpty)
        #expect(!allSwiftSources.contains("requestAuthorization("))
        // Reading/writing a CLI tool's own keychain item (Claude Code, Cursor) must delegate to
        // `/usr/bin/security`: that binary matches the item's `apple-tool:` partition, so no
        // SecurityAgent dialog appears. Direct Security.framework access fails closed and can
        // also raise prompts. Upsert with `add-generic-password -U` only — never `-A` (ACL
        // rewrite prompts), `delete-generic-password`, or `unlock-keychain`.
        #expect(allSwiftSources.contains(#""add-generic-password""#))
        #expect(allSwiftSources.contains(#""find-generic-password""#))
        #expect(!allSwiftSources.contains(#""delete-generic-password""#))
        #expect(!allSwiftSources.contains(#""unlock-keychain""#))

        let secretStoreSource = try source("Services/SecretStoreService.swift")
        #expect(secretStoreSource.contains(#""-U""#))
        // `-A` on Claude/Cursor items rewrites the ACL and can itself show a password dialog.
        #expect(!secretStoreSource.contains(#""-A""#))

        let claudeCredentialsSource = try source(
            "Providers/ClaudeCodeProvider+LocalCredentials.swift"
        )
        #expect(!claudeCredentialsSource.contains(#""auth", "status""#))
        #expect(claudeCredentialsSource.contains("writeGenericPasswordUsingSecurityTool"))
        #expect(claudeCredentialsSource.contains("compareAndSwapGenericPasswordUsingSecurityTool"))

        let cursorAgentSource = try source(
            "Providers/CursorProvider+AgentLogin.swift"
        )
        #expect(!cursorAgentSource.contains(#"arguments = ["status"]"#))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("QuotaBarApp", isDirectory: true)
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
