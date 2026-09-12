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
