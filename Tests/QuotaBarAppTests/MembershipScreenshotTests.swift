import AppKit
import SwiftUI
import Testing
@testable import QuotaBarApp

@Suite("Membership screenshot gallery")
struct MembershipScreenshotTests {
    @Test("renders representative membership cards")
    @MainActor
    func rendersMembershipCards() throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["QUOTABAR_SCREENSHOT_OUTPUT"] else {
            return
        }

        let scenarios = MembershipPreviewScenario.samples
        let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        try render(
            MembershipPreviewGallery(scenarios: scenarios),
            size: NSSize(width: 920, height: 900),
            to: outputURL.appendingPathComponent("membership-types-gallery.png")
        )

        for scenario in scenarios {
            try render(
                MembershipPreviewCard(scenario: scenario, showsCaption: false),
                size: NSSize(width: 440, height: 196),
                to: outputURL.appendingPathComponent("\(scenario.id).png")
            )
        }
    }

    @MainActor
    private func render<V: View>(_ view: V, size: NSSize, to outputURL: URL) throws {
        let root = view
            .environment(\.colorScheme, .light)
            .environment(\.locale, AppLanguage.simplifiedChinese.locale)
            .frame(width: size.width, height: size.height)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw MembershipScreenshotError.couldNotCreateBitmap
        }

        representation.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        window.orderOut(nil)

        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw MembershipScreenshotError.couldNotEncodePNG
        }
        try png.write(to: outputURL, options: .atomic)
    }
}

private enum MembershipScreenshotError: Error {
    case couldNotCreateBitmap
    case couldNotEncodePNG
}

private struct MembershipPreviewGallery: View {
    let scenarios: [MembershipPreviewScenario]

    private var rows: [MembershipPreviewRow] {
        stride(from: 0, to: scenarios.count, by: 2).map { start in
            MembershipPreviewRow(scenarios: Array(scenarios[start ..< min(start + 2, scenarios.count)]))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("会员类型界面预览")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Branding.inkStrong)
                Text("使用真实账户卡片组件与模拟配额数据")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Branding.inkMuted)
            }

            VStack(spacing: 14) {
                ForEach(rows) { row in
                    HStack(spacing: 16) {
                        ForEach(row.scenarios) { scenario in
                            MembershipPreviewCard(scenario: scenario)
                        }
                        if row.scenarios.count == 1 {
                            Color.clear.frame(width: 428, height: 188)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Branding.pageBackground)
    }
}

private struct MembershipPreviewRow: Identifiable {
    let scenarios: [MembershipPreviewScenario]
    var id: String { scenarios.first?.id ?? "empty" }
}

private struct MembershipPreviewCard: View {
    let scenario: MembershipPreviewScenario
    var showsCaption = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsCaption {
                HStack(spacing: 6) {
                    Text(scenario.tool.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Branding.inkMuted)
                    Text("/")
                        .foregroundStyle(Branding.separatorDot)
                    Text(scenario.membership)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Branding.inkStrong)
                }
                .padding(.leading, 2)
            }

            AccountCardView(
                account: scenario.account,
                language: .simplifiedChinese,
                isActive: true,
                isRecommended: false,
                recommendationReason: nil,
                isRefreshing: false,
                loadState: .loaded,
                quota: scenario.quota,
                errorMessage: nil,
                errorRequiresUserAction: false,
                canActivate: true,
                refreshCycleID: 0,
                onActivate: {},
                onRefresh: {},
                onDelete: {}
            )
        }
        .padding(6)
        .frame(width: 428, height: showsCaption ? 188 : 196, alignment: .top)
    }
}

private struct MembershipPreviewScenario: Identifiable {
    let id: String
    let tool: ToolKind
    let membership: String
    let account: Account
    let quota: QuotaSnapshot

    static let samples: [MembershipPreviewScenario] = {
        let now = Date()
        let fiveHours = now.addingTimeInterval(3 * 3600 + 24 * 60)
        let weekly = now.addingTimeInterval(4 * 24 * 3600 + 3 * 3600)
        let billing = now.addingTimeInterval(21 * 24 * 3600)

        func window(_ label: String, remaining: Double, resetAt: Date) -> QuotaWindow {
            QuotaWindow(label: label, used: 100 - remaining, limit: 100, resetAt: resetAt)
        }

        func scenario(
            id: String,
            tool: ToolKind,
            membership: String,
            email: String,
            primary: QuotaWindow?,
            secondary: QuotaWindow? = nil,
            tertiary: QuotaWindow? = nil
        ) -> MembershipPreviewScenario {
            let source = tool == .codex ? "Codex OAuth" : (tool == .cursor ? "Cursor" : "Claude Code OAuth")
            let resetCredits = tool == .codex
                ? QuotaResetCredits(availableCount: 2, credits: [], updatedAt: now)
                : nil
            return MembershipPreviewScenario(
                id: id,
                tool: tool,
                membership: membership,
                account: Account(tool: tool, name: email, createdAt: now),
                quota: QuotaSnapshot(
                    source: source,
                    accountIdentifier: email,
                    planName: membership,
                    primary: primary,
                    secondary: secondary,
                    tertiary: tertiary,
                    creditsRemaining: nil,
                    creditsTotal: nil,
                    resetCredits: resetCredits,
                    updatedAt: now,
                    accountValidUntil: membership == "Free" ? nil : billing,
                    subscriptionWillRenew: membership == "Free" ? nil : true,
                    subscriptionStatus: "active",
                    note: nil
                )
            )
        }

        return [
            scenario(id: "codex-free", tool: .codex, membership: "Free", email: "free@codex.dev", primary: window("Weekly", remaining: 82, resetAt: weekly)),
            scenario(id: "codex-plus", tool: .codex, membership: "Plus Monthly", email: "plus@codex.dev", primary: window("5h", remaining: 64, resetAt: fiveHours), secondary: window("Weekly", remaining: 38, resetAt: weekly)),
            scenario(id: "codex-pro", tool: .codex, membership: "Pro Annual", email: "pro@codex.dev", primary: window("Weekly", remaining: 71, resetAt: weekly)),
            scenario(id: "codex-team", tool: .codex, membership: "Team Monthly", email: "team@codex.dev", primary: window("5h", remaining: 93, resetAt: fiveHours), secondary: window("Weekly", remaining: 76, resetAt: weekly)),
            scenario(id: "cursor-free", tool: .cursor, membership: "Free", email: "free@cursor.dev", primary: window("Total", remaining: 100, resetAt: billing)),
            scenario(id: "cursor-pro", tool: .cursor, membership: "Pro Monthly", email: "pro@cursor.dev", primary: window("Total", remaining: 75, resetAt: billing), secondary: window("Auto", remaining: 40, resetAt: billing), tertiary: window("API", remaining: 18, resetAt: billing)),
            scenario(id: "cursor-ultra", tool: .cursor, membership: "Ultra Annual", email: "ultra@cursor.dev", primary: window("Total", remaining: 88, resetAt: billing), secondary: window("Auto", remaining: 69, resetAt: billing), tertiary: window("API", remaining: 52, resetAt: billing)),
            scenario(id: "claude-ai", tool: .claudeCode, membership: "Claude.ai", email: "member@claude.ai", primary: window("5h", remaining: 57, resetAt: fiveHours), secondary: window("7d", remaining: 84, resetAt: weekly))
        ]
    }()
}
