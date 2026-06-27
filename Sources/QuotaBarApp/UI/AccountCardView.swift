import AppKit
import SwiftUI

struct AccountCardView: View {
    let account: Account
    let language: AppLanguage
    let isActive: Bool
    let isRecommended: Bool
    let recommendationReason: String?
    let isRefreshing: Bool
    let loadState: AccountLoadState
    let quota: QuotaSnapshot?
    let errorMessage: String?
    let canActivate: Bool
    let refreshCycleID: Int
    let onActivate: () -> Void
    let onRefresh: () -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirmingDelete = false
    @State private var isHovering = false
    @State private var refreshFeedback: CardRefreshFeedback = .idle
    @State private var activeRefreshCycleID: Int = 0
    @State private var wasRefreshingInActiveCycle = false
    @State private var hideRefreshFeedbackTask: Task<Void, Never>?

    private let cardCornerRadius: CGFloat = Branding.radiusCard

    private var text: AppText { AppText(language: language) }

    private var resolvedAccountName: String {
        let trimmed = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(account.tool.displayName) Account" : trimmed
    }

    private var compactedDisplayName: String {
        compactDisplayName(resolvedAccountName)
    }

    private var displayName: String {
        return compactedDisplayName
    }

    private var shouldShowFullNameHelp: Bool {
        compactedDisplayName != resolvedAccountName
    }

    private func compactDisplayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let atIndex = trimmed.firstIndex(of: "@"), trimmed.count > 22 {
            let localPart = String(trimmed[..<atIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let domainPart = String(trimmed[trimmed.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !localPart.isEmpty {
                let domainPrefix = domainPart.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
                if !domainPrefix.isEmpty {
                    let localWithDomain = "\(localPart)@\(domainPrefix)"
                    if localWithDomain.count <= 26 {
                        return localWithDomain
                    }
                }
                if localPart.count <= 26 {
                    return localPart
                }
                return String(localPart.prefix(26))
            }
        }
        if trimmed.count <= 26 {
            return trimmed
        }
        return String(trimmed.prefix(26))
    }

    private enum SubscriptionType: Equatable {
        case apiKey
        case free
        case plus
        case pro
        case proPlus
        case ultra
        case max
        case team
        case enterprise
        case unlimited
        case claudeFirstParty
        case claudeProvider(String)
        case unknown(String)

        var label: String {
            switch self {
            case .apiKey: return "API"
            case .free: return "Free"
            case .plus: return "Plus"
            case .pro: return "Pro"
            case .proPlus: return "Pro+"
            case .ultra: return "Ultra"
            case .max: return "Max"
            case .team: return "Team"
            case .enterprise: return "Enterprise"
            case .unlimited: return "Unlimited"
            case .claudeFirstParty: return "Claude.ai"
            case .claudeProvider(let provider): return provider
            case .unknown(let raw): return raw
            }
        }

        // Plan name is descriptive metadata, not a status, so it stays neutral —
        // only quota health (green/amber/red) and the active state (blue) carry hue.
        var tint: Color { Branding.inkMuted }

        var isPaid: Bool {
            switch self {
            case .plus, .pro, .proPlus, .ultra, .max, .team, .enterprise, .unlimited:
                return true
            case .claudeFirstParty, .claudeProvider:
                return true
            case .apiKey, .free, .unknown:
                return false
            }
        }
    }

    private var planSummaryBadge: (text: String, tint: Color)? {
        guard let rawPlan = quota?.planName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPlan.isEmpty else {
            return nil
        }

        let type = subscriptionType(from: rawPlan, tool: account.tool)
        var parts = [type.label]

        if type.isPaid,
           account.tool != .claudeCode,
           let cycle = actualBillingCycle(from: rawPlan.lowercased()) {
            parts.append(text.billingCycle(cycle))
        }

        return (parts.joined(separator: " · "), type.tint)
    }

    private func subscriptionType(from rawPlan: String, tool: ToolKind) -> SubscriptionType {
        let lower = rawPlan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return .unknown(rawPlan) }

        switch tool {
        case .cursor:
            if lower.contains("free") || lower.contains("hobby") { return .free }
            if lower.contains("enterprise") { return .enterprise }
            if lower.contains("team") || lower.contains("business") { return .team }
            if lower.contains("ultra") { return .ultra }
            if lower.contains("pro+") || lower.contains("pro plus") || lower.contains("pro_plus") { return .proPlus }
            if lower.contains("pro") { return .pro }
            return .unknown(rawPlan)
        case .codex:
            if lower.contains("api key") || lower == "api" { return .apiKey }
            if lower.contains("free") || lower.contains("hobby") { return .free }
            if lower.contains("enterprise") { return .enterprise }
            if lower.contains("team") || lower.contains("business") { return .team }
            if lower.contains("unlimited") { return .unlimited }
            if lower.contains("ultra") { return .ultra }
            if lower.contains("max") { return .max }
            if lower.contains("pro+") || lower.contains("pro plus") || lower.contains("pro_plus") { return .proPlus }
            if lower.contains("pro") { return .pro }
            if lower.contains("plus") { return .plus }
            return .unknown(rawPlan)
        case .claudeCode:
            if lower == "claude.ai" || lower.contains("claude.ai") {
                return .claudeFirstParty
            }
            if lower.contains("api key") || lower == "api" {
                return .apiKey
            }
            return .claudeProvider(rawPlan)
        }
    }

    private var subscriptionDateText: String? {
        guard let quota,
              let date = quota.accountValidUntil,
              shouldShowSubscriptionDate(for: quota) else {
            return nil
        }

        if quota.subscriptionWillRenew == true {
            return text.renewsOn(date)
        }
        return text.expiresOn(date)
    }

    private func shouldShowSubscriptionDate(for quota: QuotaSnapshot) -> Bool {
        switch account.tool {
        case .codex:
            guard let rawPlan = quota.planName else { return false }
            return subscriptionType(from: rawPlan, tool: .codex).isPaid
        case .cursor:
            guard let plan = quota.planName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !plan.isEmpty else {
                return true
            }
            return subscriptionType(from: plan, tool: .cursor) != .free
        case .claudeCode:
            return true
        }
    }

    private var remainingRatio: Double? {
        quotaLimitingMetrics.compactMap(\.ratio).min()
    }

    private var remainingRatios: [Double] {
        quotaLimitingMetrics.compactMap(\.ratio)
    }

    private var metrics: [QuotaDisplayMetric] {
        quota?.orderedMetrics ?? []
    }

    private var visibleMetrics: [QuotaDisplayMetric] {
        Array(metrics.prefix(3))
    }

    private var quotaLimitingMetrics: [QuotaDisplayMetric] {
        guard account.tool == .claudeCode else { return metrics }
        var items: [QuotaDisplayMetric] = []
        if let primary = quota?.primary {
            items.append(.window(primary))
        }
        if let secondary = quota?.secondary {
            items.append(.window(secondary))
        }
        if let remaining = quota?.creditsRemaining,
           let total = quota?.creditsTotal,
           total > 0 {
            items.append(.credits(remaining: remaining, total: total, periodEnd: quota?.periodEnd))
        }
        return items
    }

    private var hasAnyQuotaRemaining: Bool {
        if remainingRatios.contains(where: { $0 > 0.001 }) {
            return true
        }
        return false
    }

    private var hasExhaustedQuotaWindow: Bool {
        remainingRatios.contains { $0 <= 0.001 }
    }

    private var isInitialLoadingWithoutQuota: Bool {
        quota == nil && (isRefreshing || loadState == .loadingInitial || loadState == .refreshing)
    }

    private func actualBillingCycle(from lowercasedPlan: String) -> BillingCycle? {
        if lowercasedPlan.contains("annual")
            || lowercasedPlan.contains("yearly")
            || lowercasedPlan.contains("year")
            || lowercasedPlan.contains("年度") {
            return .annual
        }

        if lowercasedPlan.contains("monthly")
            || lowercasedPlan.contains("month")
            || lowercasedPlan.contains("月度") {
            return .monthly
        }

        return nil
    }

    private var status: AccountVisualStatus {
        if errorMessage != nil, quota != nil { return .stale }
        if errorMessage != nil { return .error }
        if isRefreshing || loadState == .refreshing || loadState == .loadingInitial { return .refreshing }
        guard let quota else { return .pending }
        if isStaleOrCachedQuota(quota) { return .stale }
        if quota.isQuotaBlocked == true { return .exhausted }
        if metrics.isEmpty {
            if account.tool == .claudeCode {
                return .healthy
            }
            return .noQuota
        }
        if hasExhaustedQuotaWindow { return .exhausted }
        if account.tool == .claudeCode, quotaLimitingMetrics.isEmpty, !metrics.isEmpty {
            return .healthy
        }
        if hasAnyQuotaRemaining {
            guard let remainingRatio else { return .healthy }
            return remainingRatio <= 0.20 ? .warning : .healthy
        }
        guard let remainingRatio else { return .noQuota }
        if remainingRatio <= 0.001 { return .exhausted }
        if remainingRatio <= 0.20 { return .warning }
        return .healthy
    }

    private func isStaleOrCachedQuota(_ quota: QuotaSnapshot) -> Bool {
        if loadState == .stale {
            return true
        }
        return quota.source.range(of: "cache", options: .caseInsensitive) != nil
    }

    private var shouldShowStatusBadge: Bool {
        if shouldHideRefreshingStatusBadge {
            return false
        }
        switch status {
        case .healthy, .warning, .exhausted:
            return false
        case .refreshing, .pending, .noQuota, .stale, .error:
            return true
        }
    }

    private var shouldHideRefreshingStatusBadge: Bool {
        guard refreshBadge != nil else { return false }
        if case .refreshing = status {
            return true
        }
        return false
    }

    private var cardFill: Color {
        if isActive {
            return isHovering ? Branding.activeHoverCardSurface : Branding.activeCardSurface
        }
        if isHovering { return Branding.hoverCardSurface }
        return Branding.cardSurface
    }

    private var cardStroke: Color {
        if isActive { return Branding.borderSelected }
        if isHovering { return Branding.borderSelected.opacity(0.44) }
        return Branding.controlStroke.opacity(0.64)
    }

    private var shouldRevealActions: Bool {
        isActive || isHovering
    }

    // Trailing space the header reserves so the account name never collides with
    // the text action buttons. English labels are wider than the CJK ones.
    private var actionZoneWidth: CGFloat {
        switch language {
        case .english:
            return isActive ? 120 : 156
        default:
            return isActive ? 86 : 124
        }
    }

    private var metadataItems: [(text: String, tint: Color, weight: Font.Weight)] {
        var items: [(text: String, tint: Color, weight: Font.Weight)] = []

        if isActive {
            items.append((text.string(.currentBadge), Branding.accentBlueDark, .semibold))
        }

        // Descriptive plan info reads as secondary text, not an alert.
        if let planSummaryBadge {
            items.append((planSummaryBadge.text, planSummaryBadge.tint, .medium))
        }

        if isRecommended, !isActive {
            items.append((recommendationReason ?? text.string(.recommendedReason), Branding.success, .semibold))
        }

        if shouldShowStatusBadge {
            items.append((status.title(text), status.tint, .semibold))
        }

        if let refreshBadge {
            items.append((refreshBadge.text, refreshBadge.tint, .semibold))
        }

        // Renewal date is the lowest-priority metadata — quietest tone.
        if let subscriptionDateText {
            items.append((subscriptionDateText, Branding.inkSubtle, .regular))
        }

        return items
    }

    private var hasMetadataRow: Bool {
        !metadataItems.isEmpty
    }

    private var footerMessage: (message: String, color: Color)? {
        if let errorMessage {
            if quota != nil {
                return (text.staleQuotaMessage(errorMessage), Branding.warning)
            }
            return (errorMessage, Branding.danger)
        }
        return nil
    }

    private var hasFooterContent: Bool {
        footerMessage != nil
    }

    private var secondaryPanelTitle: String {
        quota?.secondaryPanelTitle ?? "Weekly"
    }

    private var metricTiles: [(title: String, metric: QuotaDisplayMetric?)] {
        if visibleMetrics.isEmpty {
            return [
                (quota?.primary?.label ?? "5h", quota?.primaryPanelMetric),
                (secondaryPanelTitle, quota?.secondaryPanelMetric)
            ]
        }
        return visibleMetrics.map { ($0.title, $0) }
    }

    private var contentSpacing: CGFloat {
        if hasFooterContent {
            return 6
        }
        return 9
    }

    private var verticalPadding: CGFloat {
        if hasFooterContent {
            return 10
        }
        return 11
    }

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            header

            if isInitialLoadingWithoutQuota {
                LoadingQuotaPlaceholder(language: language)
            } else {
                CompactQuotaMetricStrip(
                    tiles: metricTiles,
                    fallbackResetAt: quota?.periodEnd,
                    language: language
                )
            }

            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .frame(height: DashboardLayout.accountCardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(cardStroke, lineWidth: isActive ? 1.15 : 1)
        )
        .overlay(alignment: .topTrailing) {
            actionZone
                .frame(width: actionZoneWidth, height: 24, alignment: .trailing)
                .opacity(shouldRevealActions ? 1 : 0)
                .allowsHitTesting(shouldRevealActions)
                .accessibilityHidden(!shouldRevealActions)
                .padding(.top, verticalPadding)
                .padding(.trailing, 12)
        }
        .shadow(
            color: isActive ? Branding.shadowPopover.opacity(0.58) : Branding.cardShadow.opacity(0.82),
            radius: isActive ? Branding.activeCardShadowRadius : Branding.cardShadowRadius,
            y: isActive ? Branding.activeCardShadowY : Branding.cardShadowY
        )
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: shouldRevealActions)
        .animation(reduceMotion ? nil : .quotaFluid, value: isActive)
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .onTapGesture {
            guard canActivate, !isActive else { return }
            onActivate()
        }
        .pointingHandCursor(canActivate && !isActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint(cardAccessibilityHint)
        .accessibilityAction(named: Text(text.useAccount(resolvedAccountName))) {
            guard canActivate, !isActive else { return }
            onActivate()
        }
        .accessibilityAction(named: Text(text.refreshAccount(resolvedAccountName))) {
            guard !isRefreshing else { return }
            onRefresh()
        }
        .onChange(of: refreshCycleID) { _ in
            handleRefreshCycleChange()
        }
        .onChange(of: isRefreshing) { refreshing in
            handleRefreshStateChange(isRefreshing: refreshing)
        }
        .onDisappear {
            hideRefreshFeedbackTask?.cancel()
            hideRefreshFeedbackTask = nil
        }
        .confirmationDialog(text.string(.deletePromptTitle), isPresented: $isConfirmingDelete) {
            Button(text.deleteAccountTitle(displayName), role: .destructive, action: onDelete)
            Button(text.string(.cancel), role: .cancel) {}
        } message: {
            Text(text.string(.deleteLocalOnly))
        }
    }

    private var cardAccessibilityLabel: String {
        var parts = [resolvedAccountName]
        if isActive {
            parts.append(text.string(.currentBadge))
        }
        parts.append(contentsOf: metadataItems.map(\.text))
        if let quota {
            parts.append(text.updatedAt(quota.updatedAt))
        }
        if let footerMessage {
            parts.append(footerMessage.message)
        }
        return parts.joined(separator: ", ")
    }

    private var cardAccessibilityHint: String {
        if isActive {
            return text.refreshAccount(resolvedAccountName)
        }
        return text.useAccount(resolvedAccountName)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(displayName)
                    .font(.system(size: 15.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Branding.inkStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(shouldShowFullNameHelp ? account.name : "")
                    .layoutPriority(1)

                if isRecommended, !isActive {
                    InlineMetadataLabel(text: text.string(.recommended), tint: Branding.success, weight: .semibold)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                }

                Spacer(minLength: 8)
            }

            if hasMetadataRow {
                metadataRow
            }
        }
        .padding(.trailing, actionZoneWidth + 8)
    }

    private var metadataRow: some View {
        HStack(spacing: 5) {
            ForEach(Array(metadataItems.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Circle()
                        .fill(Branding.separatorDot)
                        .frame(width: 3, height: 3)
                }

                InlineMetadataLabel(text: item.text, tint: item.tint, weight: item.weight)
                    .metadataActivePill(isActive && item.text == text.string(.currentBadge))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
    }

    private var actionZone: some View {
        HStack(spacing: 2) {
            if !isActive {
                CardTextActionButton(
                    title: text.string(.useAccount),
                    tint: Branding.actionActivate,
                    softTint: Branding.actionActivateSoft,
                    isEnabled: canActivate
                ) {
                    onActivate()
                }
                .help(text.useAccount(resolvedAccountName))
                .accessibilityLabel(text.useAccount(resolvedAccountName))
            }

            CardTextActionButton(
                title: text.string(.refresh),
                tint: Branding.actionRefresh,
                softTint: Branding.actionRefreshSoft,
                isEnabled: !isRefreshing,
                action: onRefresh
            )
            .help(text.refreshAccount(resolvedAccountName))
            .accessibilityLabel(text.refreshAccount(resolvedAccountName))

            CardTextActionButton(
                title: text.string(.delete),
                tint: Branding.actionDestructive,
                softTint: Branding.actionDestructiveSoft
            ) {
                isConfirmingDelete = true
            }
            .help(text.string(.delete))
            .accessibilityLabel(text.string(.delete))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var footer: some View {
        if hasFooterContent {
            VStack(alignment: .leading, spacing: 4) {
                if let footerMessage {
                    Text(footerMessage.message)
                        .font(.system(size: 10.2, weight: .regular))
                        .foregroundStyle(footerMessage.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(footerMessage.message)
                }
            }
        }
    }

    private var refreshBadge: (text: String, tint: Color)? {
        switch refreshFeedback {
        case .idle:
            return nil
        case .refreshing:
            return (
                refreshText(.refreshing),
                Branding.accentBlueDark
            )
        case .success:
            return (
                refreshText(.success),
                Branding.success
            )
        }
    }
    private func refreshText(_ state: CardRefreshFeedback) -> String {
        switch language {
        case .english:
            switch state {
            case .refreshing: return "Refreshing..."
            case .success: return "Updated"
            case .idle: return ""
            }
        case .simplifiedChinese:
            switch state {
            case .refreshing: return "刷新中..."
            case .success: return "已更新"
            case .idle: return ""
            }
        case .traditionalChinese:
            switch state {
            case .refreshing: return "刷新中..."
            case .success: return "已更新"
            case .idle: return ""
            }
        }
    }

    private func handleRefreshCycleChange() {
        guard refreshCycleID != activeRefreshCycleID else { return }
        activeRefreshCycleID = refreshCycleID
        wasRefreshingInActiveCycle = false
        refreshFeedback = .idle
        hideRefreshFeedbackTask?.cancel()
        hideRefreshFeedbackTask = nil
    }

    private func handleRefreshStateChange(isRefreshing: Bool) {
        if isRefreshing {
            if refreshCycleID > 0 {
                hideRefreshFeedbackTask?.cancel()
                hideRefreshFeedbackTask = nil
                refreshFeedback = .refreshing
                wasRefreshingInActiveCycle = true
            }
            return
        }

        guard wasRefreshingInActiveCycle else { return }
        wasRefreshingInActiveCycle = false

        if case .refreshing = refreshFeedback, errorMessage == nil {
            refreshFeedback = .success
            let completedCycleID = activeRefreshCycleID
            hideRefreshFeedbackTask?.cancel()
            hideRefreshFeedbackTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                if refreshFeedback == .success, activeRefreshCycleID == completedCycleID {
                    refreshFeedback = .idle
                    hideRefreshFeedbackTask = nil
                }
            }
        } else {
            refreshFeedback = .idle
            hideRefreshFeedbackTask?.cancel()
            hideRefreshFeedbackTask = nil
        }
    }
}

private enum CardRefreshFeedback: Equatable {
    case idle
    case refreshing
    case success
}

private struct CardTextActionButton: View {
    let title: String
    let tint: Color
    let softTint: Color
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    // Keep the semantic tint visible at rest; hover adds only a soft affordance.
    private var textColor: Color {
        if !isEnabled {
            return Branding.inkSubtle.opacity(0.5)
        }
        if !isHovering {
            return tint.opacity(0.78)
        }
        return tint
    }

    private var backgroundColor: Color {
        guard isEnabled, isHovering else { return .clear }
        return softTint.opacity(0.72)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 22)
                .foregroundStyle(textColor)
                .background(
                    RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: Branding.radiusSmallControl, style: .continuous))
        }
        .buttonStyle(.quotaInteractive(isEnabled: isEnabled))
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

private enum AccountVisualStatus {
    case healthy
    case refreshing
    case pending
    case noQuota
    case stale
    case warning
    case exhausted
    case error

    func title(_ text: AppText) -> String {
        switch self {
        case .healthy: return text.string(.normal)
        case .refreshing: return text.string(.refreshing)
        case .pending: return text.string(.pendingRefresh)
        case .noQuota: return text.string(.noQuota)
        case .stale: return text.string(.staleData)
        case .warning: return text.string(.nearLimit)
        case .exhausted: return text.string(.exhausted)
        case .error: return text.string(.error)
        }
    }

    var tint: Color {
        switch self {
        case .healthy: return Branding.success
        case .refreshing: return Branding.accentBlue
        case .pending, .noQuota: return Branding.inkMuted
        case .stale: return Branding.warning
        case .warning: return Branding.warning
        case .exhausted, .error: return Branding.danger
        }
    }

}

struct ToolLogoIcon: View {
    let tool: ToolKind
    let size: CGFloat

    private var fallbackSymbol: String {
        switch tool {
        case .codex:
            return "terminal.fill"
        case .cursor:
            return "square.grid.2x2.fill"
        case .claudeCode:
            return "asterisk"
        }
    }

    private var preparedImage: NSImage? {
        ToolIconImageCache.image(named: tool.logoResourceName, size: size)
    }

    var body: some View {
        if let icon = preparedImage {
            Image(nsImage: icon)
                .interpolation(.high)
                .antialiased(true)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.78, weight: .semibold))
                .foregroundStyle(Branding.inkStrong)
                .frame(width: size, height: size)
        }
    }
}

@MainActor
private enum ToolIconImageCache {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)-\(size)"
        if let cached = cache[key] {
            return cached
        }
        guard let url = AppResourceLocator.url(forResource: name, withExtension: "png", subdirectory: "Logos"),
              let loaded = NSImage(contentsOf: url) else {
            return nil
        }
        let icon = (loaded.copy() as? NSImage) ?? loaded
        icon.size = NSSize(width: size, height: size)
        cache[key] = icon
        return icon
    }
}

private struct InlineMetadataLabel: View {
    let text: String
    let tint: Color
    let weight: Font.Weight

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: weight))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(tint)
    }
}

private extension View {
    @ViewBuilder
    func metadataActivePill(_ isActive: Bool) -> some View {
        if isActive {
            // Soft-tint chip rather than a solid fill: marks the active account
            // without out-shouting the name and quota figures above/below it.
            self
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(
                    RoundedRectangle(cornerRadius: Branding.radiusPill, style: .continuous)
                        .fill(Branding.accentBlueSoft)
                )
        } else {
            self
        }
    }
}

private struct LoadingQuotaPlaceholder: View {
    let language: AppLanguage

    private var text: AppText { AppText(language: language) }

    var body: some View {
        CompactQuotaMetricStrip(
            tiles: [
                ("5h", nil),
                ("Weekly", nil)
            ],
            fallbackResetAt: nil,
            language: language,
            fallbackDetail: text.string(.refreshing)
        )
    }
}

private struct CompactQuotaMetricStrip: View {
    let tiles: [(title: String, metric: QuotaDisplayMetric?)]
    let fallbackResetAt: Date?
    let language: AppLanguage
    var fallbackDetail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                CompactQuotaMetricTile(
                    title: tile.title,
                    metric: tile.metric,
                    fallbackResetAt: fallbackResetAt,
                    language: language,
                    fallbackDetail: fallbackDetail
                )
            }
        }
    }
}

private struct CompactQuotaMetricTile: View {
    let title: String
    let metric: QuotaDisplayMetric?
    let fallbackResetAt: Date?
    let language: AppLanguage
    let fallbackDetail: String?

    private var text: AppText { AppText(language: language) }

    private var state: (ratio: Double, resetAt: Date?, isKnown: Bool) {
        guard let metric,
              let ratio = metric.ratio else {
            return (0, nil, false)
        }
        return (ratio, metric.resetAt, true)
    }

    private var tint: Color {
        guard state.isKnown else { return Branding.inkSubtle }
        if state.ratio <= 0.001 { return Branding.danger }
        if state.ratio <= 0.20 { return Branding.warning }
        return Branding.success
    }

    private var percentTextColor: Color {
        guard state.isKnown else { return Branding.inkSubtle }
        if state.ratio <= 0.20 {
            return tint
        }
        return Branding.inkStrong
    }

    var body: some View {
        let resolved = state

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center) {
                Text(text.quotaLabel(title))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Branding.inkMuted)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(resolved.isKnown ? "\(Int((resolved.ratio * 100).rounded()))%" : "--")
                    .font(.system(size: 16.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(percentTextColor)
                    .monospacedDigit()
            }

            RatioBar(value: resolved.isKnown ? resolved.ratio : 0, tint: tint)

            Text(detailText(resolved: resolved))
                .font(.system(size: 9.8, weight: .regular))
                .foregroundStyle(Branding.inkSubtle)
                .lineLimit(1)
                .frame(minHeight: 12, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
    }

    private func detailText(resolved: (ratio: Double, resetAt: Date?, isKnown: Bool)) -> String {
        if resolved.isKnown, let resetAt = resolved.resetAt ?? fallbackResetAt {
            return text.resetAt(resetAt)
        }
        if let fallbackDetail {
            return fallbackDetail
        }
        return text.string(.waitingData)
    }
}

private struct RatioBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Branding.track)
                    .overlay(
                        Capsule()
                            .stroke(Branding.iconHighlight, lineWidth: 0.5)
                    )
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * value, value > 0 ? 7 : 0))
            }
        }
        .frame(height: 7)
    }
}
