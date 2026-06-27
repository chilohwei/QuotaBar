import Foundation

enum AppResourceLocator {
    static func url(
        forResource name: String,
        withExtension resourceExtension: String,
        subdirectory: String? = nil
    ) -> URL? {
        let fileName = "\(name).\(resourceExtension)"
        let bundleName = "QuotaBar_QuotaBarApp.bundle"
        let fileManager = FileManager.default

        let bundleCandidates = [
            Bundle.module,
            Bundle.main
        ]
            .flatMap { bundle -> [URL?] in
                [
                    bundle.url(forResource: name, withExtension: resourceExtension, subdirectory: subdirectory),
                    bundle.url(forResource: name, withExtension: resourceExtension)
                ]
            }

        let resourceCandidates = [
            bundleURL(from: Bundle.main.resourceURL, bundleName: bundleName, subdirectory: subdirectory, fileName: fileName),
            bundleURL(from: Bundle.main.resourceURL, bundleName: bundleName, subdirectory: nil, fileName: fileName),
            bundleURL(
                from: Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("Resources", isDirectory: true),
                bundleName: bundleName,
                subdirectory: subdirectory,
                fileName: fileName
            ),
            bundleURL(
                from: Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("Resources", isDirectory: true),
                bundleName: bundleName,
                subdirectory: nil,
                fileName: fileName
            )
        ]

        return (bundleCandidates + resourceCandidates)
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
