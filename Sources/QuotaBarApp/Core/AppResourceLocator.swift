import Foundation

enum AppResourceLocator {
    /// Anchors `Bundle(for:)` to this module's binary so we can locate the
    /// SwiftPM resource bundle in dev/test builds.
    private final class BundleToken {}

    static func url(
        forResource name: String,
        withExtension resourceExtension: String,
        subdirectory: String? = nil
    ) -> URL? {
        let fileName = "\(name).\(resourceExtension)"
        let bundleName = "QuotaBar_QuotaBarApp.bundle"
        let fileManager = FileManager.default

        // Deliberately avoid `Bundle.module`: SwiftPM's generated accessor only
        // probes the app-root and the compile-time `.build` path and calls
        // `fatalError` when both miss, which crashes the packaged app (where the
        // resource bundle lives in `Contents/Resources`). These bundles never
        // trap on access.
        let searchBundles = [Bundle.main, Bundle(for: BundleToken.self)]

        // 1) Let each bundle resolve the resource directly.
        let directCandidates = searchBundles.flatMap { bundle -> [URL?] in
            [
                bundle.url(forResource: name, withExtension: resourceExtension, subdirectory: subdirectory),
                bundle.url(forResource: name, withExtension: resourceExtension)
            ]
        }

        // 2) Probe the SwiftPM resource bundle by path relative to each bundle's
        //    resource/root dir and the executable's `Contents/Resources` dir.
        let baseDirectories: [URL?] = searchBundles.flatMap { bundle -> [URL?] in
            [
                bundle.resourceURL,
                bundle.bundleURL,
                // In `swift test` the resource bundle is a sibling of the
                // `.xctest` bundle, i.e. one level above its bundleURL.
                bundle.bundleURL.deletingLastPathComponent()
            ]
        } + [
            Bundle.main.executableURL?
                .deletingLastPathComponent() // Contents/MacOS
                .deletingLastPathComponent() // Contents
                .appendingPathComponent("Resources", isDirectory: true)
        ]

        let probedCandidates = baseDirectories.flatMap { base -> [URL?] in
            [
                bundleURL(from: base, bundleName: bundleName, subdirectory: subdirectory, fileName: fileName),
                bundleURL(from: base, bundleName: bundleName, subdirectory: nil, fileName: fileName)
            ]
        }

        return (directCandidates + probedCandidates)
            .compactMap { $0 }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func bundleURL(
        from baseURL: URL?,
        bundleName: String,
        subdirectory: String?,
        fileName: String
    ) -> URL? {
        guard let baseURL else { return nil }
        var url = baseURL.appendingPathComponent(bundleName, isDirectory: true)
        if let subdirectory {
            url.appendPathComponent(subdirectory, isDirectory: true)
        }
        return url.appendingPathComponent(fileName)
    }
}
