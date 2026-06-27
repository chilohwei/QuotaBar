import AppKit
import SwiftUI

enum Branding {
    // Surfaces — neutral backgrounds, layered light → recessed.
    static let pageBackground = adaptive(light: rgb(0.952, 0.956, 0.964), dark: rgb(0.092, 0.098, 0.112))
    static let cardSurface = adaptive(light: rgb(0.980, 0.984, 0.990), dark: rgb(0.160, 0.171, 0.195))
    static let hoverCardSurface = adaptive(light: rgb(0.988, 0.991, 0.996), dark: rgb(0.185, 0.198, 0.224))
    static let activeCardSurface = adaptive(light: rgb(0.986, 0.991, 1.0), dark: rgb(0.152, 0.178, 0.218))
    static let activeHoverCardSurface = adaptive(light: rgb(0.992, 0.996, 1.0), dark: rgb(0.164, 0.196, 0.244))
    static let controlSurface = adaptive(light: NSColor.white.withAlphaComponent(0.86), dark: rgb(0.188, 0.202, 0.232, 0.94))
    static let chipSurface = adaptive(light: rgb(0.930, 0.934, 0.940), dark: rgb(0.202, 0.216, 0.246))
    static let menuSurface = adaptive(light: NSColor.white, dark: rgb(0.150, 0.160, 0.184, 0.98))
    static let menuItemSelectedSurface = adaptive(light: rgb(0.890, 0.935, 1.0), dark: rgb(0.150, 0.200, 0.268, 0.92))

    // Text — one contrast scale, dark enough to read at small sizes.
    static let inkStrong = adaptive(light: rgb(0.08, 0.09, 0.11), dark: rgb(0.930, 0.945, 0.970))
    static let ink = adaptive(light: rgb(0.12, 0.13, 0.15), dark: rgb(0.860, 0.885, 0.925))
    static let inkMuted = adaptive(light: rgb(0.37, 0.39, 0.43), dark: rgb(0.740, 0.775, 0.825))
    static let inkSubtle = adaptive(light: rgb(0.44, 0.46, 0.50), dark: rgb(0.665, 0.705, 0.765))

    // Borders & strokes.
    static let borderSubtle = adaptive(light: NSColor.white.withAlphaComponent(0.76), dark: rgb(1.0, 1.0, 1.0, 0.075))
    static let controlStroke = adaptive(light: rgb(0.0, 0.0, 0.0, 0.055), dark: rgb(1.0, 1.0, 1.0, 0.095))
    static let borderSelected = adaptive(light: rgb(0.10, 0.43, 0.98, 0.20), dark: rgb(0.55, 0.72, 0.95, 0.18))
    static let separatorDot = adaptive(light: rgb(0.0, 0.0, 0.0, 0.12), dark: rgb(1.0, 1.0, 1.0, 0.18))

    // Semantic colors — the only hues in the UI: blue = interactive/active,
    // green = healthy, amber = warning, red = exhausted/error. Each has a soft tint.
    static let accentBlue = adaptive(light: rgb(0.10, 0.43, 0.98), dark: rgb(0.365, 0.580, 0.900))
    static let accentBlueDark = adaptive(light: rgb(0.06, 0.30, 0.92), dark: rgb(0.590, 0.735, 0.965))
    static let accentBlueSoft = adaptive(light: rgb(0.90, 0.95, 1.0), dark: rgb(0.130, 0.188, 0.278))
    static let success = adaptive(light: rgb(0.10, 0.72, 0.27), dark: rgb(0.360, 0.700, 0.455))
    static let successSoft = adaptive(light: rgb(0.88, 0.97, 0.89), dark: rgb(0.130, 0.235, 0.165))
    static let warning = adaptive(light: rgb(0.86, 0.50, 0.06), dark: rgb(0.870, 0.625, 0.320))
    static let warningSoft = adaptive(light: rgb(1.0, 0.94, 0.83), dark: rgb(0.285, 0.215, 0.120))
    static let danger = adaptive(light: rgb(1.0, 0.20, 0.18), dark: rgb(0.900, 0.405, 0.385))
    static let dangerSoft = adaptive(light: rgb(1.0, 0.91, 0.91), dark: rgb(0.270, 0.125, 0.135))
    static let actionActivate = accentBlueDark
    static let actionActivateSoft = accentBlueSoft
    static let actionRefresh = accentBlue
    static let actionRefreshSoft = accentBlueSoft
    static let actionDestructive = danger
    static let actionDestructiveSoft = dangerSoft

    // Effects.
    static let track = adaptive(light: rgb(0.0, 0.0, 0.0, 0.075), dark: rgb(1.0, 1.0, 1.0, 0.105))
    static let iconHighlight = adaptive(light: rgb(0.0, 0.0, 0.0, 0.08), dark: rgb(1.0, 1.0, 1.0, 0.055))
    static let cardShadow = adaptive(light: rgb(0.0, 0.0, 0.0, 0.025), dark: rgb(0.0, 0.0, 0.0, 0.24))
    static let shadowPopover = adaptive(light: rgb(0.0, 0.0, 0.0, 0.055), dark: rgb(0.0, 0.0, 0.0, 0.34))
    static let primaryActionText = adaptive(light: NSColor.white, dark: rgb(0.945, 0.970, 1.0))

    // Shape and elevation tokens.
    static let radiusCard: CGFloat = 12
    static let radiusMenu: CGFloat = 12
    static let radiusSidebarItem: CGFloat = 12
    static let radiusControl: CGFloat = 10
    static let radiusSegment: CGFloat = 9
    static let radiusSmallControl: CGFloat = 7
    static let radiusPill: CGFloat = 5
    static let cardShadowRadius: CGFloat = 6
    static let activeCardShadowRadius: CGFloat = 8
    static let cardShadowY: CGFloat = 2
    static let activeCardShadowY: CGFloat = 2.5

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
    }

    @MainActor
    static func makeAppIcon(size: CGFloat = 256) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let bounds = CGRect(origin: rect.origin, size: rect.size)
            let iconRect = bounds.insetBy(dx: size * 0.105, dy: size * 0.105)
            let radius = iconRect.width * 0.225
            let shape = NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius)

            NSColor.white.setFill()
            shape.fill()

            NSColor(calibratedWhite: 0, alpha: 0.08).setStroke()
            shape.lineWidth = max(size * 0.006, 1)
            shape.stroke()

            drawBrandMark(in: iconRect.insetBy(dx: size * 0.075, dy: size * 0.075), monochrome: false)
            return true
        }
        return image
    }

    @MainActor
    static func makeMenuBarIcon(size: CGFloat = 16) -> NSImage {
        let image = makeBrandMarkIcon(size: size, monochrome: true)
        image.isTemplate = true
        return image
    }

    @MainActor
    static func makeBrandMarkIcon(size: CGFloat, monochrome: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let bounds = CGRect(origin: rect.origin, size: rect.size)
            drawBrandMark(in: bounds, monochrome: monochrome)
            return true
        }
        return image
    }

    @MainActor
    static func drawBrandMark(in rect: CGRect, monochrome: Bool) {
        let size = min(rect.width, rect.height)
        let base = CGRect(
            x: rect.midX - size / 2,
            y: rect.midY - size / 2,
            width: size,
            height: size
        )

        let center = NSPoint(x: base.midX, y: base.midY)
        let gearRadius = size * (monochrome ? 0.49 : 0.445)
        let gear = gearPath(center: center, radius: gearRadius, toothDepth: 0.14, toothCount: 10)

        if monochrome {
            NSColor.white.setFill()
            gear.fill()
            drawPromptGlyph(in: base, color: .clear, clearsDestination: true)
        } else {
            let gradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.21, green: 0.77, blue: 0.94, alpha: 1),
                NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.96, alpha: 1),
                NSColor(calibratedRed: 0.56, green: 0.38, blue: 0.96, alpha: 1)
            ])
            gradient?.draw(in: gear, angle: 315)
            drawPromptGlyph(in: base, color: .white, clearsDestination: false)
        }
    }

    private static func gearPath(center: NSPoint, radius: CGFloat, toothDepth: CGFloat, toothCount: Int) -> NSBezierPath {
        let path = NSBezierPath()
        let segments = max(toothCount * 18, 120)

        for index in 0 ..< segments {
            let progress = Double(index) / Double(segments)
            let angle = (-90.0 + progress * 360.0) * .pi / 180.0
            let wave = (1 + cos(Double(toothCount) * angle)) / 2
            let resolvedRadius = radius * (1 - toothDepth + toothDepth * CGFloat(wave))
            let point = NSPoint(
                x: center.x + CGFloat(cos(angle)) * resolvedRadius,
                y: center.y + CGFloat(sin(angle)) * resolvedRadius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        return path
    }

    private static func drawPromptGlyph(in base: CGRect, color: NSColor, clearsDestination: Bool) {
        let size = min(base.width, base.height)
        let oldOperation = NSGraphicsContext.current?.compositingOperation
        if clearsDestination {
            NSGraphicsContext.current?.compositingOperation = .clear
            NSColor.clear.setStroke()
        } else {
            color.setStroke()
        }

        let lineWidth = max(size * 0.080, 1.3)
        let chevron = NSBezierPath()
        chevron.lineWidth = lineWidth
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.move(to: NSPoint(x: base.minX + size * 0.31, y: base.midY + size * 0.14))
        chevron.line(to: NSPoint(x: base.minX + size * 0.50, y: base.midY - size * 0.02))
        chevron.line(to: NSPoint(x: base.minX + size * 0.31, y: base.midY - size * 0.18))
        chevron.stroke()

        let promptBar = NSBezierPath()
        promptBar.lineWidth = lineWidth
        promptBar.lineCapStyle = .round
        promptBar.move(to: NSPoint(x: base.minX + size * 0.58, y: base.midY - size * 0.16))
        promptBar.line(to: NSPoint(x: base.minX + size * 0.76, y: base.midY - size * 0.16))
        promptBar.stroke()

        if clearsDestination {
            NSGraphicsContext.current?.compositingOperation = oldOperation ?? .sourceOver
        }
    }
}
