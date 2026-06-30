import Foundation
import Security
import Testing
@testable import QuotaBarApp

@Suite("Secret store service")
struct SecretStoreServiceTests {
    @Test("new secrets use Keychain and delete cleanly")
    func savesNewSecretsToKeychainAndDeletesThem() throws {
        let fixture = try SecretStoreFixture()
        defer { fixture.cleanup() }

        try fixture.store.saveSecret("fresh-token", accountKey: "account.1.secret")

        #expect(try fixture.store.readSecret(accountKey: "account.1.secret") == "fresh-token")
        #expect(!FileManager.default.fileExists(atPath: fixture.legacySecretsFile.path))

        try fixture.writeLegacySecrets([
            "account.1.secret": "stale-token",
            "account.2.secret": "other-token"
        ])

        try fixture.store.deleteSecret(accountKey: "account.1.secret")

        #expect(try fixture.keychain.readString(service: fixture.keychainService, account: "account.1.secret") == nil)
        let remaining = try fixture.readLegacySecrets()
        #expect(remaining == ["account.2.secret": "other-token"])
    }

    @Test("legacy JSON secret is migrated to Keychain and removed from disk")
    func migratesLegacySecretToKeychain() throws {
        let fixture = try SecretStoreFixture()
        defer { fixture.cleanup() }
        try fixture.writeLegacySecrets([
            "account.1.secret": "legacy-token"
        ])

        #expect(try fixture.store.readSecret(accountKey: "account.1.secret") == "legacy-token")
        #expect(try fixture.keychain.readString(service: fixture.keychainService, account: "account.1.secret") == "legacy-token")
        #expect(!FileManager.default.fileExists(atPath: fixture.legacySecretsFile.path))
    }

    @Test("system keychain query is local-only")
    func systemKeychainQueryIsLocalOnly() throws {
        let query = SystemSecretKeychainClient.baseQuery(
            service: "com.chiloh.QuotaBar.tests",
            account: "account.1.secret"
        )

        #expect(query[kSecAttrService as String] as? String == "com.chiloh.QuotaBar.tests")
        #expect(query[kSecAttrAccount as String] as? String == "account.1.secret")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }
}

private struct SecretStoreFixture {
    let directory: URL
    let legacySecretsFile: URL
    let keychainService: String
    let keychain: InMemorySecretKeychainClient
    let store: SecretStoreService

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarSecretStoreTests-\(UUID().uuidString)", isDirectory: true)
        legacySecretsFile = directory.appendingPathComponent("secrets.json")
        keychainService = "com.chiloh.QuotaBar.tests.\(UUID().uuidString)"
        keychain = InMemorySecretKeychainClient()
        store = SecretStoreService(
            keychain: keychain,
            keychainService: keychainService,
            legacySecretsFile: legacySecretsFile
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func writeLegacySecrets(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        try data.write(to: legacySecretsFile, options: .atomic)
    }

    func readLegacySecrets() throws -> [String: String] {
        let data = try Data(contentsOf: legacySecretsFile)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class InMemorySecretKeychainClient: SecretKeychainClient {
    private var storage: [String: Data] = [:]

    func saveSecret(_ data: Data, service: String, account: String) throws {
        storage[key(service: service, account: account)] = data
    }

    func readSecret(service: String, account: String) throws -> Data? {
        storage[key(service: service, account: account)]
    }

    func deleteSecret(service: String, account: String) throws {
        storage[key(service: service, account: account)] = nil
    }

    func readString(service: String, account: String) throws -> String? {
        guard let data = try readSecret(service: service, account: account) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func key(service: String, account: String) -> String {
        "\(service)\n\(account)"
    }
}
