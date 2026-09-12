import AppKit
import SwiftUI

struct ToolLogoIcon: View {
    let tool: ToolKind
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

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
                .renderingMode(tool == .codex ? .template : .original)
                .interpolation(.high)
                .antialiased(true)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Branding.inkStrong)
                .frame(width: size, height: size)
                .background {
                    if tool == .cursor, colorScheme == .dark {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.90))
                    }
                }
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
