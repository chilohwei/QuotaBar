import AppKit
import SwiftUI

extension Animation {
    /// Smooth, lightly-damped spring for view transitions (settings, selection).
    static let quotaFluid = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Snappier spring for direct manipulation feedback (button press).
    static let quotaSnappy = Animation.spring(response: 0.26, dampingFraction: 0.66)
}

struct QuotaInteractiveButtonStyle: ButtonStyle {
    var isEnabled = true

    func makeBody(configuration: Configuration) -> some View {
        QuotaInteractiveButtonBody(
            configuration: configuration,
            isEnabled: isEnabled
        )
    }
}

private struct QuotaInteractiveButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isEnabled: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .opacity(resolvedOpacity)
            .scaleEffect(configuration.isPressed ? 0.97 : isHovering ? 1.008 : 1)
            .animation(.quotaSnappy, value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
            .pointingHandCursor(isEnabled)
    }

    private var resolvedOpacity: Double {
        guard isEnabled else { return 0.58 }
        if configuration.isPressed { return 0.78 }
        return 1
    }
}

extension ButtonStyle where Self == QuotaInteractiveButtonStyle {
    static func quotaInteractive(isEnabled: Bool = true) -> QuotaInteractiveButtonStyle {
        QuotaInteractiveButtonStyle(isEnabled: isEnabled)
    }
}

extension View {
    func pointingHandCursor(_ isEnabled: Bool = true) -> some View {
        background(CursorRegion(cursor: .pointingHand, isEnabled: isEnabled))
    }
}

private struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor
    let isEnabled: Bool

    func makeNSView(context _: Context) -> CursorRegionView {
        let view = CursorRegionView()
        view.cursor = isEnabled ? cursor : nil
        return view
    }

    func updateNSView(_ nsView: CursorRegionView, context _: Context) {
        nsView.cursor = isEnabled ? cursor : nil
    }
}

private final class CursorRegionView: NSView {
    var cursor: NSCursor? {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let cursor {
            addCursorRect(bounds, cursor: cursor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
