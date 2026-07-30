import AppKit

struct StatusBarQuotaEntry {
    let tool: ToolKind
    let accountName: String
    let remainingPercent: Int?
    let source: String?
    let updatedAt: Date?
    let availabilityStatus: QuotaAvailabilityStatus?
    let lines: [StatusBarQuotaLine]
    var alternativeAccountName: String?
}

enum StatusBarQuotaWarningLevel: Equatable {
    case normal
    case low
    case exhausted
}

struct StatusBarQuotaLine {
    let text: String
    let level: StatusBarQuotaWarningLevel
}

@MainActor
struct StatusBarQuotaDisplay {
    let items: [StatusBarQuotaEntry]

    var contentWidth: CGFloat {
        let itemWidths = items
            .map(StatusBarQuotaItemView.itemWidth(for:))
            .reduce(0, +)
        return ceil(
            StatusBarQuotaContentView.contentHorizontalInset * 2
                + StatusBarQuotaContentView.logoSize
                + StatusBarQuotaContentView.logoQuotaSpacing
                + itemWidths
        )
    }

    var preferredStatusItemLength: CGFloat {
        max(NSStatusItem.squareLength, contentWidth + 4)
    }
}

@MainActor
final class StatusBarQuotaContentView: NSView {
    static let preferredHeight: CGFloat = 22
    static let contentHeight: CGFloat = 20
    static let contentHorizontalInset: CGFloat = 2
    static let logoSize: CGFloat = 17
    static let logoQuotaSpacing: CGFloat = 6

    private let logoImageView = NSImageView()
    private let stackView = NSStackView()
    private var currentDisplay: StatusBarQuotaDisplay?

    init(fallbackIcon: NSImage) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = false

        let iconCopy = fallbackIcon.copy() as? NSImage ?? fallbackIcon
        iconCopy.isTemplate = true
        logoImageView.image = iconCopy
        logoImageView.imageScaling = .scaleProportionallyDown
        logoImageView.contentTintColor = .labelColor
        logoImageView.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .gravityAreas
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(logoImageView)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            logoImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentHorizontalInset),
            logoImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: Self.logoSize),
            logoImageView.heightAnchor.constraint(equalToConstant: Self.logoSize),

            stackView.leadingAnchor.constraint(equalTo: logoImageView.trailingAnchor, constant: Self.logoQuotaSpacing),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentHorizontalInset),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        configure(display: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(display: StatusBarQuotaDisplay?) {
        currentDisplay = display
        logoImageView.contentTintColor = .labelColor

        guard let display else {
            removeQuotaItems()
            stackView.isHidden = true
            invalidateIntrinsicContentSize()
            return
        }

        removeQuotaItems()
        stackView.isHidden = false

        for item in display.items {
            stackView.addArrangedSubview(StatusBarQuotaItemView(item: item))
        }

        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: currentDisplay?.contentWidth ?? Self.logoSize + Self.contentHorizontalInset * 2,
            height: Self.preferredHeight
        )
    }

    private func removeQuotaItems() {
        for subview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
    }
}

@MainActor
private final class StatusBarQuotaItemView: NSView {
    static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 8.0, weight: .semibold)
    private static let toolIconSize: CGFloat = 14
    private static let iconTextSpacing: CGFloat = 3.5
    private static let lineHeight: CGFloat = 10
    private static let lineSpacing: CGFloat = 0
    private static let separatorWidth: CGFloat = 1
    private static let separatorLeading: CGFloat = 6
    private static let separatorTrailing: CGFloat = 6
    private static let alternativeDotSize: CGFloat = 5
    private static let alternativeDotSpacing: CGFloat = 3

    private let separatorView = NSView()
    private let toolLogoView: StatusBarToolLogoView
    private let labelStack = NSStackView()
    private let item: StatusBarQuotaEntry

    init(item: StatusBarQuotaEntry) {
        self.item = item
        self.toolLogoView = StatusBarToolLogoView(tool: item.tool, size: Self.toolIconSize)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.52).cgColor
        separatorView.translatesAutoresizingMaskIntoConstraints = false

        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = Self.lineSpacing
        labelStack.distribution = .fillEqually
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        for line in item.lines {
            let label = NSTextField(labelWithString: line.text)
            label.font = Self.lineFont
            switch line.level {
            case .exhausted:
                label.textColor = .systemRed
            case .low:
                label.textColor = .systemOrange
            case .normal:
                label.textColor = .labelColor
            }
            label.alignment = .left
            label.lineBreakMode = .byClipping
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.heightAnchor.constraint(equalToConstant: Self.lineHeight).isActive = true
            labelStack.addArrangedSubview(label)
        }

        addSubview(separatorView)
        addSubview(toolLogoView)
        addSubview(labelStack)

        NSLayoutConstraint.activate([
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.separatorLeading),
            separatorView.centerYAnchor.constraint(equalTo: centerYAnchor),
            separatorView.widthAnchor.constraint(equalToConstant: Self.separatorWidth),
            separatorView.heightAnchor.constraint(equalToConstant: 12),

            toolLogoView.leadingAnchor.constraint(equalTo: separatorView.trailingAnchor, constant: Self.separatorTrailing),
            toolLogoView.centerYAnchor.constraint(equalTo: centerYAnchor),
            toolLogoView.widthAnchor.constraint(equalToConstant: Self.toolIconSize),
            toolLogoView.heightAnchor.constraint(equalToConstant: Self.toolIconSize),

            labelStack.leadingAnchor.constraint(equalTo: toolLogoView.trailingAnchor, constant: Self.iconTextSpacing),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if item.alternativeAccountName != nil {
            // A quiet green dot: this tool's active account is out of quota, but a
            // recommended alternative is ready (details in the tooltip).
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.layer?.cornerRadius = Self.alternativeDotSize / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: labelStack.trailingAnchor, constant: Self.alternativeDotSpacing),
                dot.trailingAnchor.constraint(equalTo: trailingAnchor),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -5),
                dot.widthAnchor.constraint(equalToConstant: Self.alternativeDotSize),
                dot.heightAnchor.constraint(equalToConstant: Self.alternativeDotSize)
            ])
        } else {
            labelStack.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.itemWidth(for: item),
            height: StatusBarQuotaContentView.contentHeight
        )
    }

    static func itemWidth(for item: StatusBarQuotaEntry) -> CGFloat {
        let widest = item.lines
            .map { $0.text.size(withAttributes: [.font: lineFont]).width }
            .max() ?? 0
        let dotReserve = item.alternativeAccountName != nil
            ? alternativeDotSpacing + alternativeDotSize
            : 0
        return ceil(
            separatorLeading
                + separatorWidth
                + separatorTrailing
                + toolIconSize
                + iconTextSpacing
                + widest
                + dotReserve
        )
    }
}

@MainActor
private final class StatusBarToolLogoView: NSView {
    private let tool: ToolKind
    private let logoSize: CGFloat
    private let imageView = NSImageView()

    init(tool: ToolKind, size: CGFloat) {
        self.tool = tool
        self.logoSize = size
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: logoSize, height: logoSize)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateImage()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateImage()
    }

    private func updateImage() {
        imageView.image = StatusBarToolLogoImageCache.image(
            for: tool,
            size: logoSize,
            color: resolvedIconColor()
        )
    }

    private func resolvedIconColor() -> NSColor {
        let appearance = effectiveAppearance
        let fallback = Self.fallbackIconColor(for: appearance)
        var color = fallback
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? fallback
        }
        return color
    }

    private static func fallbackIconColor(for appearance: NSAppearance) -> NSColor {
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        return match == .darkAqua || match == .vibrantDark ? .white : .black
    }
}

@MainActor
enum StatusBarToolLogoImageCache {
    private static var tintedCache: [String: NSImage] = [:]

    static func image(for tool: ToolKind, size: CGFloat, color: NSColor) -> NSImage {
        let resolvedColor = color.usingColorSpace(.deviceRGB) ?? .labelColor
        let key = [
            tool.rawValue,
            String(format: "%.2f", size),
            String(format: "%.3f", resolvedColor.redComponent),
            String(format: "%.3f", resolvedColor.greenComponent),
            String(format: "%.3f", resolvedColor.blueComponent),
            String(format: "%.3f", resolvedColor.alphaComponent)
        ].joined(separator: "-")

        if let cached = tintedCache[key] {
            return cached
        }

        let sourceImage: NSImage
        if let url = AppResourceLocator.url(
            forResource: tool.logoResourceName,
            withExtension: "png",
            subdirectory: "Logos"
        ),
           let loaded = NSImage(contentsOf: url) {
            sourceImage = loaded
        } else {
            sourceImage = fallbackTemplateImage(for: tool)
        }

        let image = rasterizedIcon(from: sourceImage, size: size, color: resolvedColor)
        tintedCache[key] = image
        return image
    }

    private static func rasterizedIcon(from image: NSImage, size: CGFloat, color: NSColor) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff) else {
            let fallback = image.copy() as? NSImage ?? image
            fallback.size = NSSize(width: size, height: size)
            fallback.isTemplate = true
            return fallback
        }

        let resolvedColor = color.usingColorSpace(.deviceRGB) ?? .white

        if source.hasAlpha {
            // Fast path: keep the source alpha and recolor with one composite
            // instead of visiting every pixel.
            if let tinted = compositeTintedIcon(source: source, size: size, color: resolvedColor) {
                return tinted
            }
        }

        return perPixelLuminanceIcon(source: source, size: size, color: resolvedColor)
            ?? {
                let fallback = image.copy() as? NSImage ?? image
                fallback.size = NSSize(width: size, height: size)
                fallback.isTemplate = true
                return fallback
            }()
    }

    private static func compositeTintedIcon(source: NSBitmapImageRep, size: CGFloat, color: NSColor) -> NSImage? {
        guard let output = makeOutputRep(width: source.pixelsWide, height: source.pixelsHigh),
              let context = NSGraphicsContext(bitmapImageRep: output) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: source.pixelsWide, height: source.pixelsHigh)
        source.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let rendered = NSImage(size: NSSize(width: size, height: size))
        rendered.addRepresentation(output)
        rendered.isTemplate = false
        return rendered
    }

    private static func perPixelLuminanceIcon(source: NSBitmapImageRep, size: CGFloat, color: NSColor) -> NSImage? {
        guard let output = makeOutputRep(width: source.pixelsWide, height: source.pixelsHigh) else {
            return nil
        }

        for y in 0 ..< source.pixelsHigh {
            for x in 0 ..< source.pixelsWide {
                guard let pixel = source.colorAt(x: x, y: y),
                      let rgb = pixel.usingColorSpace(.deviceRGB) else {
                    output.setColor(.clear, atX: x, y: y)
                    continue
                }

                let alpha = alphaFromLuminance(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                output.setColor(
                    NSColor(
                        deviceRed: color.redComponent,
                        green: color.greenComponent,
                        blue: color.blueComponent,
                        alpha: alpha * color.alphaComponent
                    ),
                    atX: x,
                    y: y
                )
            }
        }

        let rendered = NSImage(size: NSSize(width: size, height: size))
        rendered.addRepresentation(output)
        rendered.isTemplate = false
        return rendered
    }

    private static func makeOutputRep(width: Int, height: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    private static func alphaFromLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
        if luminance <= 0.08 { return 0 }
        if luminance >= 0.26 { return 1 }
        return (luminance - 0.08) / 0.18
    }

    private static func fallbackTemplateImage(for tool: ToolKind) -> NSImage {
        switch tool {
        case .codex:
            return Branding.makeBrandMarkIcon(size: 32, monochrome: true)
        case .cursor:
            return NSImage(systemSymbolName: "cube.fill", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil)
                ?? Branding.makeBrandMarkIcon(size: 32, monochrome: true)
        case .claudeCode:
            return NSImage(systemSymbolName: "asterisk", accessibilityDescription: nil)
                ?? Branding.makeBrandMarkIcon(size: 32, monochrome: true)
        }
    }
}
