import AppKit
import Testing
@testable import QuotaBarApp

@Suite("App resources")
struct AppResourceLocatorTests {
    @Test("tool logos load from packaged resources")
    func toolLogosLoadFromPackagedResources() throws {
        for name in ["codex", "cursor", "claude"] {
            let url = try #require(AppResourceLocator.url(forResource: name, withExtension: "png", subdirectory: "Logos"))
            #expect(NSImage(contentsOf: url) != nil)
        }
    }

    @MainActor
    @Test("status bar tool logos render visible pixels")
    func statusBarToolLogosRenderVisiblePixels() throws {
        for tool in ToolKind.allCases {
            let image = StatusBarToolLogoImageCache.image(for: tool, size: 16, color: .white)
            let tiffRepresentation = try #require(image.tiffRepresentation)
            let representation = try #require(NSBitmapImageRep(data: tiffRepresentation))
            var visiblePixels = 0

            for y in 0 ..< representation.pixelsHigh {
                for x in 0 ..< representation.pixelsWide {
                    if (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                        visiblePixels += 1
                    }
                }
            }

            #expect(visiblePixels > 0)
        }
    }
}
