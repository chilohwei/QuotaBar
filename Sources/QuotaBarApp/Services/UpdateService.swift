import CryptoKit
import Foundation

enum UpdateCheckResult: Sendable {
    case upToDate(currentVersion: String, latestVersion: String)
    case updateAvailable(UpdateRelease)
}

struct UpdateRelease: Sendable {
    let tagName: String
    let version: String
    let currentVersion: String
    let releaseURL: URL
    let assetURL: URL
    let assetName: String
    let assetDigest: String
}

struct UpdateDownloadProgress: Sendable {
    let bytesWritten: Int64
    let totalBytes: Int64?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(bytesWritten) / Double(totalBytes), 0), 1)
    }
}

enum UpdateServiceError: LocalizedError {
    case invalidReleaseURL
    case invalidAssetURL
    case invalidAssetDigest(String)
    case missingReleaseAsset
    case missingAssetDigest(String)
    case releaseNotFound
    case requestFailed(Int)
    case digestMismatch(expected: String, actual: String)
    case installLocationNotWritable(String)
    case installerLaunchFailed(String)
    case untrustedReleaseSource(String)

    var errorDescription: String? {
        switch self {
        case .invalidReleaseURL:
            return "GitHub Release 地址无效"
        case .invalidAssetURL:
            return "GitHub Release 安装包地址无效"
        case .invalidAssetDigest(let digest):
            return "GitHub Release 安装包校验值无效：\(digest)"
        case .missingReleaseAsset:
            return "未找到适合当前设备的安装包"
        case .missingAssetDigest(let assetName):
            return "安装包缺少 SHA256 校验值：\(assetName)"
        case .releaseNotFound:
            return "未找到可用的 GitHub Release"
        case .requestFailed(let code):
            return "GitHub Release 查询失败，HTTP \(code)"
        case .digestMismatch(let expected, let actual):
            return "安装包校验失败，期望 \(expected)，实际 \(actual)"
        case .installLocationNotWritable(let path):
            return "安装目录不可写：\(path)"
        case .installerLaunchFailed(let message):
            return "无法启动安装程序：\(message)"
        case .untrustedReleaseSource(let value):
            return "更新来源不是 QuotaBar 官方 GitHub Release：\(value)"
        }
    }
}

enum OfficialReleaseSource {
    private static let expectedHost = "github.com"
    private static let expectedRepositoryPath = "/chilohwei/quotabar"

    static func isOfficialReleaseURL(_ url: URL, tagName: String) -> Bool {
        guard isHTTPSGitHubURL(url) else { return false }
        let path = url.path.lowercased()
        let expectedPath = "\(expectedRepositoryPath)/releases/tag/\(tagName.lowercased())"
        return path == expectedPath
    }

    static func isOfficialAssetURL(_ url: URL, tagName: String? = nil, assetName: String) -> Bool {
        guard isHTTPSGitHubURL(url) else { return false }
        let path = url.path.lowercased()
        let tagSegment = tagName.map { "/\($0.lowercased())/" } ?? "/"
        guard path.hasPrefix("\(expectedRepositoryPath)/releases/download/"),
              path.contains(tagSegment) else {
            return false
        }
        return url.lastPathComponent == assetName
    }

    private static func isHTTPSGitHubURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == expectedHost
    }
}

struct UpdateService: Sendable {
    private let latestReleaseURL = URL(string: "https://api.github.com/repos/chilohwei/QuotaBar/releases/latest")!

    func checkForUpdates() async throws -> UpdateCheckResult {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        AppLog.update.info("Checking updates from GitHub Releases, current=\(currentVersion, privacy: .public)")
        let release = try await fetchLatestRelease()
        let latestVersion = release.normalizedVersion

        guard AppVersion(latestVersion) > AppVersion(currentVersion) else {
            AppLog.update.info("No update available, latest=\(latestVersion, privacy: .public)")
            return .upToDate(currentVersion: currentVersion, latestVersion: latestVersion)
        }

        guard let releaseURL = URL(string: release.htmlURL) else {
            throw UpdateServiceError.invalidReleaseURL
        }
        guard OfficialReleaseSource.isOfficialReleaseURL(releaseURL, tagName: release.tagName) else {
            throw UpdateServiceError.untrustedReleaseSource(release.htmlURL)
        }
        guard let asset = release.bestAssetForCurrentMac else {
            throw UpdateServiceError.missingReleaseAsset
        }
        guard let assetURL = URL(string: asset.browserDownloadURL) else {
            throw UpdateServiceError.invalidAssetURL
        }
        guard OfficialReleaseSource.isOfficialAssetURL(assetURL, tagName: release.tagName, assetName: asset.name) else {
            throw UpdateServiceError.untrustedReleaseSource(asset.browserDownloadURL)
        }
        let assetDigest: String
        if let rawDigest = asset.digest {
            assetDigest = try ReleaseAssetDigest.sha256Hex(from: rawDigest)
        } else if let digestAsset = release.sha256Asset(for: asset) {
            assetDigest = try await fetchReleaseAssetDigest(digestAsset, tagName: release.tagName)
        } else {
            throw UpdateServiceError.missingAssetDigest(asset.name)
        }
        AppLog.update.info("Update available, version=\(latestVersion, privacy: .public), asset=\(asset.name, privacy: .public)")

        return .updateAvailable(UpdateRelease(
            tagName: release.tagName,
            version: latestVersion,
            currentVersion: currentVersion,
            releaseURL: releaseURL,
            assetURL: assetURL,
            assetName: asset.name,
            assetDigest: assetDigest
        ))
    }

    func installAndRelaunch(
        _ release: UpdateRelease,
        progress: (@Sendable (UpdateDownloadProgress) -> Void)? = nil
    ) async throws {
        AppLog.update.info("Starting update install, version=\(release.version, privacy: .public), asset=\(release.assetName, privacy: .public)")
        guard OfficialReleaseSource.isOfficialAssetURL(release.assetURL, tagName: release.tagName, assetName: release.assetName) else {
            throw UpdateServiceError.untrustedReleaseSource(release.assetURL.absoluteString)
        }
        let downloadURL = try await downloadReleaseAsset(release, progress: progress)
        try verifyDownloadedAsset(at: downloadURL, digest: release.assetDigest)
        let appURL = Bundle.main.bundleURL
        let destinationURL = installationDestination(for: appURL)
        try validateInstallDestination(destinationURL)
        let installerDirectory = try createPrivateTemporaryDirectory(prefix: "quotabar-installer")
        let logURL = installerDirectory.appendingPathComponent("install-update.log")
        try createPrivateLog(at: logURL)
        let scriptURL = try writeInstallerScript(
            dmgURL: downloadURL,
            destinationURL: destinationURL,
            logURL: logURL,
            expectedVersion: release.version,
            in: installerDirectory
        )
        try launchInstaller(
            scriptURL: scriptURL,
            dmgURL: downloadURL,
            destinationURL: destinationURL,
            logURL: logURL,
            expectedVersion: release.version
        )
        AppLog.update.info("Launched update installer, log=\(logURL.path, privacy: .public)")
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("QuotaBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateServiceError.releaseNotFound
        }
        guard http.statusCode != 404 else {
            throw UpdateServiceError.releaseNotFound
        }
        guard 200 ..< 300 ~= http.statusCode else {
            throw UpdateServiceError.requestFailed(http.statusCode)
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func downloadReleaseAsset(
        _ release: UpdateRelease,
        progress: (@Sendable (UpdateDownloadProgress) -> Void)?
    ) async throws -> URL {
        var request = URLRequest(url: release.assetURL)
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("QuotaBar", forHTTPHeaderField: "User-Agent")

        let downloader = UpdateAssetDownloader(progress: progress)
        let (downloadedURL, response) = try await downloader.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateServiceError.releaseNotFound
        }
        guard 200 ..< 300 ~= http.statusCode else {
            throw UpdateServiceError.requestFailed(http.statusCode)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let destination = directory.appendingPathComponent(release.assetName)
        try FileManager.default.moveItem(at: downloadedURL, to: destination)
        return destination
    }

    private func fetchReleaseAssetDigest(_ asset: GitHubReleaseAsset, tagName: String) async throws -> String {
        guard let url = URL(string: asset.browserDownloadURL) else {
            throw UpdateServiceError.invalidAssetURL
        }
        guard OfficialReleaseSource.isOfficialAssetURL(url, tagName: tagName, assetName: asset.name) else {
            throw UpdateServiceError.untrustedReleaseSource(asset.browserDownloadURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("QuotaBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateServiceError.releaseNotFound
        }
        guard 200 ..< 300 ~= http.statusCode else {
            throw UpdateServiceError.requestFailed(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UpdateServiceError.invalidAssetDigest(asset.name)
        }
        return try ReleaseAssetDigest.sha256Hex(from: text)
    }

    private func verifyDownloadedAsset(at url: URL, digest: String?) throws {
        guard let digest else {
            throw UpdateServiceError.missingAssetDigest(url.lastPathComponent)
        }
        let expected = try ReleaseAssetDigest.sha256Hex(from: digest)
        let actual = try Self.sha256Hex(of: url)
        guard actual == expected else {
            throw UpdateServiceError.digestMismatch(expected: expected, actual: actual)
        }
        AppLog.update.info("Verified update SHA256 for \(url.lastPathComponent, privacy: .public)")
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func installationDestination(for appURL: URL) -> URL {
        let path = appURL.path
        if path.hasPrefix("/Volumes/") {
            return URL(fileURLWithPath: "/Applications")
                .appendingPathComponent(appURL.lastPathComponent, isDirectory: true)
        }
        return appURL
    }

    private func validateInstallDestination(_ destinationURL: URL) throws {
        let parent = destinationURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateServiceError.installLocationNotWritable(parent.path)
        }
    }

    private func writeInstallerScript(
        dmgURL: URL,
        destinationURL: URL,
        logURL: URL,
        expectedVersion: String,
        in directory: URL
    ) throws -> URL {
        let script = #"""
#!/bin/zsh
set -euo pipefail

DMG="$1"
DEST="$2"
OLD_PID="$3"
LOG="$4"
EXPECTED_VERSION="$5"
MOUNT_DIR=""

exec >>"$LOG" 2>&1
echo "Starting QuotaBar update install at $(date)"

cleanup() {
    if [[ -n "${MOUNT_DIR:-}" ]]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    fi
}

finish() {
    local status=$?
    cleanup
    if [[ "$status" -ne 0 && -e "$DEST" ]]; then
        open "$DEST" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap finish EXIT

for _ in {1..120}; do
    if ! kill -0 "$OLD_PID" 2>/dev/null; then
        break
    fi
    sleep 0.25
done
if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Old QuotaBar process did not exit in time"
    exit 1
fi

ATTACH_OUTPUT="$(hdiutil attach "$DMG" -nobrowse -readonly)"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | sed -n 's#^/dev/[^[:space:]]*[[:space:]]*Apple_HFS[[:space:]]*##p' | tail -1)"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    echo "Unable to resolve mounted DMG path"
    printf '%s\n' "$ATTACH_OUTPUT"
    exit 1
fi

APP_SOURCE="$(find "$MOUNT_DIR" -maxdepth 3 -name "QuotaBar.app" -type d | head -1)"
if [[ -z "$APP_SOURCE" || ! -d "$APP_SOURCE" ]]; then
    echo "QuotaBar.app not found in DMG"
    exit 1
fi

mkdir -p "$(dirname "$DEST")"
TMP_DEST="${DEST}.update-tmp"
BACKUP_DEST="${DEST}.previous"
rm -rf "$TMP_DEST" "$BACKUP_DEST"

ditto "$APP_SOURCE" "$TMP_DEST"
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TMP_DEST/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$ACTUAL_BUNDLE_ID" != "com.chiloh.QuotaBar" ]]; then
    echo "Unexpected bundle identifier: ${ACTUAL_BUNDLE_ID:-missing}"
    exit 1
fi
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TMP_DEST/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "Unexpected bundle version: ${ACTUAL_VERSION:-missing}; expected $EXPECTED_VERSION"
    exit 1
fi
if [[ ! -x "$TMP_DEST/Contents/MacOS/QuotaBar" ]]; then
    echo "QuotaBar executable missing in update bundle"
    exit 1
fi
codesign --verify --deep --strict "$TMP_DEST"
echo "Quarantine attributes are preserved for unsigned/Homebrew distribution."

if [[ -e "$DEST" ]]; then
    mv "$DEST" "$BACKUP_DEST"
fi
if ! mv "$TMP_DEST" "$DEST"; then
    echo "Unable to move updated app into place"
    if [[ -e "$BACKUP_DEST" && ! -e "$DEST" ]]; then
        mv "$BACKUP_DEST" "$DEST"
    fi
    exit 1
fi
rm -rf "$BACKUP_DEST"

open "$DEST"
rm -f "$DMG"
echo "QuotaBar update install completed at $(date)"
"""#

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let scriptURL = directory.appendingPathComponent("install-update.zsh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func createPrivateTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private func createPrivateLog(at url: URL) throws {
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func launchInstaller(
        scriptURL: URL,
        dmgURL: URL,
        destinationURL: URL,
        logURL: URL,
        expectedVersion: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            scriptURL.path,
            dmgURL.path,
            destinationURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            logURL.path,
            expectedVersion
        ]

        do {
            try process.run()
        } catch {
            throw UpdateServiceError.installerLaunchFailed(error.localizedDescription)
        }
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: String
    let assets: [GitHubReleaseAsset]

    var normalizedVersion: String {
        let raw = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("v") || raw.hasPrefix("V") {
            return String(raw.dropFirst())
        }
        return raw.isEmpty ? (name ?? "0.0.0") : raw
    }

    var bestAssetForCurrentMac: GitHubReleaseAsset? {
        let lowercasedAssets = assets.filter {
            $0.name.lowercased().hasSuffix(".dmg")
        }
        let preferred = Self.currentArchitectureAssetToken
        return lowercasedAssets.first { $0.name.lowercased().contains(preferred) }
            ?? lowercasedAssets.first { $0.name.lowercased().contains("universal") }
    }

    func sha256Asset(for asset: GitHubReleaseAsset) -> GitHubReleaseAsset? {
        let expectedNames = [
            "\(asset.name).sha256",
            asset.name.replacingOccurrences(of: ".dmg", with: ".dmg.sha256")
        ].map { $0.lowercased() }
        return assets.first { expectedNames.contains($0.name.lowercased()) }
    }

    private static var currentArchitectureAssetToken: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "universal"
        #endif
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case assets
    }
}

private final class UpdateAssetDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (UpdateDownloadProgress) -> Void)?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?

    init(progress: (@Sendable (UpdateDownloadProgress) -> Void)?) {
        self.progress = progress
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = request.timeoutInterval
                configuration.timeoutIntervalForResource = max(request.timeoutInterval, 120)
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                self.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session?.invalidateAndCancel()
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progress?(UpdateDownloadProgress(bytesWritten: totalBytesWritten, totalBytes: expected))
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response else {
            finish(.failure(UpdateServiceError.releaseNotFound))
            return
        }
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("quotabar-download-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success((destination, response)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.finishTasksAndInvalidate()
        session = nil
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    let digest: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

struct AppVersion: Comparable {
    let components: [Int]

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = (trimmed.hasPrefix("v") || trimmed.hasPrefix("V"))
            ? String(trimmed.dropFirst())
            : trimmed
        let parsed = withoutPrefix
            .split { !$0.isNumber }
            .compactMap { Int($0) }
        components = parsed.isEmpty ? [0] : parsed
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

enum ReleaseAssetDigest {
    static func sha256Hex(from raw: String) throws -> String {
        let lowercased = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let firstHex = lowercased
            .split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) {
            return String(firstHex)
        }
        let hex: String
        if lowercased.hasPrefix("sha256:") {
            hex = String(lowercased.dropFirst("sha256:".count))
        } else {
            hex = lowercased
        }

        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateServiceError.invalidAssetDigest(raw)
        }
        return hex
    }
}
