import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Update service")
struct UpdateServiceTests {
    @Test("version comparison handles prefixes and suffixes")
    func appVersionComparison() {
        #expect(AppVersion("v1.2.10") > AppVersion("1.2.9"))
        #expect(AppVersion("1.2") == AppVersion("1.2.0"))
        #expect(AppVersion("1.2.0-beta.1") > AppVersion("1.1.9"))
    }

    @Test("release asset digest accepts GitHub SHA256 format")
    func releaseAssetDigestParsing() throws {
        let hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

        #expect(try ReleaseAssetDigest.sha256Hex(from: "sha256:\(hex)") == hex)
        #expect(try ReleaseAssetDigest.sha256Hex(from: hex.uppercased()) == hex)
        #expect(try ReleaseAssetDigest.sha256Hex(from: "\(hex)  QuotaBar.dmg") == hex)
    }

    @Test("release asset digest rejects missing SHA256")
    func releaseAssetDigestRejectsInvalidValues() {
        #expect(throws: UpdateServiceError.self) {
            try ReleaseAssetDigest.sha256Hex(from: "md5:abc")
        }
    }

    @Test("official update source accepts only QuotaBar release assets")
    func officialUpdateSourceValidation() throws {
        let releaseURL = try #require(URL(string: "https://github.com/chilohwei/QuotaBar/releases/tag/v1.2.3"))
        let assetURL = try #require(URL(string: "https://github.com/chilohwei/QuotaBar/releases/download/v1.2.3/QuotaBar-1.2.3-arm64.dmg"))
        let otherRepoURL = try #require(URL(string: "https://github.com/example/QuotaBar/releases/download/v1.2.3/QuotaBar-1.2.3-arm64.dmg"))
        let wrongTagURL = try #require(URL(string: "https://github.com/chilohwei/QuotaBar/releases/download/v1.2.2/QuotaBar-1.2.3-arm64.dmg"))

        #expect(OfficialReleaseSource.isOfficialReleaseURL(releaseURL, tagName: "v1.2.3"))
        #expect(OfficialReleaseSource.isOfficialAssetURL(assetURL, tagName: "v1.2.3", assetName: "QuotaBar-1.2.3-arm64.dmg"))
        #expect(!OfficialReleaseSource.isOfficialAssetURL(otherRepoURL, tagName: "v1.2.3", assetName: "QuotaBar-1.2.3-arm64.dmg"))
        #expect(!OfficialReleaseSource.isOfficialAssetURL(wrongTagURL, tagName: "v1.2.3", assetName: "QuotaBar-1.2.3-arm64.dmg"))
    }

    @Test("quota HTTP retry classification is shared")
    func quotaHTTPRetryClassification() {
        #expect(QuotaHTTPClient.isRetryableNetworkError(URLError(.timedOut)))
        #expect(!QuotaHTTPClient.isRetryableNetworkError(URLError(.badURL)))
        #expect(QuotaHTTPClient.isRetryableNetworkError(QuotaHTTPError(
            operation: "test",
            statusCode: 429,
            isRetryable: true
        )))
    }
}
