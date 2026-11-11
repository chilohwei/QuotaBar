import AppKit
import Testing
@testable import QuotaBarApp

@Suite("App resources")
struct AppResourceLocatorTests {
    @Test("tool logos load from packaged resources")
    func toolLogosLoadFromPackagedResources() throws {
        for name in ToolKind.allCases.map(\.logoResourceName) {
            let url = try #require(AppResourceLocator.url(forResource: name, withExtension: "png", subdirectory: "Logos"))
            #expect(NSImage(contentsOf: url) != nil)
        }
    }

    @MainActor
    @Test("status bar tool logos share the same visible longest edge")
    func statusBarToolLogosRenderVisiblePixels() throws {
        for tool in ToolKind.allCases {
            let image = StatusBarToolLogoImageCache.image(for: tool, size: 16, color: .white)
            let tiffRepresentation = try #require(image.tiffRepresentation)
            let representation = try #require(NSBitmapImageRep(data: tiffRepresentation))
            var minX = representation.pixelsWide
            var minY = representation.pixelsHigh
            var maxX = -1
            var maxY = -1

            for y in 0 ..< representation.pixelsHigh {
                for x in 0 ..< representation.pixelsWide {
                    if (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                }
            }

            #expect(minX <= maxX && minY <= maxY)
            let visibleWidth = CGFloat(maxX - minX + 1) / CGFloat(representation.pixelsWide) * image.size.width
            let visibleHeight = CGFloat(maxY - minY + 1) / CGFloat(representation.pixelsHigh) * image.size.height
            #expect(abs(max(visibleWidth, visibleHeight) - 16) < 0.5)
        }
    }
}
