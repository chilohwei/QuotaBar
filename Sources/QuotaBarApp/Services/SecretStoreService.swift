import Foundation
import Security

enum SecretStoreError: LocalizedError {
    case dataEncoding
    case dataDecoding
    case keychain(OSStatus)
    case missingData

    var errorDescription: String? {
        switch self {
        case .dataEncoding:
            return "凭据编码失败"
        case .dataDecoding:
            return "凭据解码失败"
        case .keychain(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "钥匙串访问失败：\(message)"
            }
            return "钥匙串访问失败，错误码 \(status)"
        case .missingData:
            return "本地凭据不存在，请重新导入或手动添加账号"
        }
    }
}

protocol SecretKeychainClient {
    func saveSecret(_ data: Data, service: String, account: String) throws
    func readSecret(service: String, account: String) throws -> Data?
    func deleteSecret(service: String, account: String) throws
}

struct SecretStoreService {
    static let defaultKeychainService = "com.chiloh.QuotaBar.secrets"

    private let keychain: any SecretKeychainClient
    private let fileManager = FileManager.default
    private let keychainService: String
    private let legacySecretsFile: URL

    init(
        keychain: any SecretKeychainClient = SystemSecretKeychainClient(),
        keychainService: String = Self.defaultKeychainService,
        legacySecretsFile: URL = AppPaths.secretsFile
    ) {
        self.keychain = keychain
        self.keychainService = keychainService
        self.legacySecretsFile = legacySecretsFile
    }

    func saveSecret(_ secret: String, accountKey: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw SecretStoreError.dataEncoding
        }
        try keychain.saveSecret(data, service: keychainService, account: accountKey)
        try? removeLegacySecret(accountKey: accountKey)
    }

    func readSecret(accountKey: String) throws -> String {
        if let data = try keychain.readSecret(service: keychainService, account: accountKey) {
            guard let secret = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.dataDecoding
            }
            return secret
        }

        if let legacySecret = try loadLegacyStore()[accountKey] {
            try saveSecret(legacySecret, accountKey: accountKey)
            return legacySecret
        }

        throw SecretStoreError.missingData
    }

    func deleteSecret(accountKey: String) throws {
        try keychain.deleteSecret(service: keychainService, account: accountKey)
        try? removeLegacySecret(accountKey: accountKey)
    }

    private func loadLegacyStore() throws -> [String: String] {
        guard fileManager.fileExists(atPath: legacySecretsFile.path) else {
            return [:]
        }
        let data = try Data(contentsOf: legacySecretsFile)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func saveLegacyStore(_ store: [String: String]) throws {
        try fileManager.createDirectory(
            at: legacySecretsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(store)
        try data.write(to: legacySecretsFile, options: .atomic)

        // Legacy compatibility only. New secrets live in macOS Keychain.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacySecretsFile.path)
    }

    private func removeLegacySecret(accountKey: String) throws {
        guard fileManager.fileExists(atPath: legacySecretsFile.path) else {
            return
        }
        var legacy = try loadLegacyStore()
        guard legacy.removeValue(forKey: accountKey) != nil else {
            return
        }
        if legacy.isEmpty {
            try fileManager.removeItem(at: legacySecretsFile)
            return
        }
        try saveLegacyStore(legacy)
    }
}

struct SystemSecretKeychainClient: SecretKeychainClient {
    func saveSecret(_ data: Data, service: String, account: String) throws {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus != errSecDuplicateItem {
            throw SecretStoreError.keychain(addStatus)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let updateStatus = SecItemUpdate(
            Self.baseQuery(service: service, account: account) as CFDictionary,
            attributes as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw SecretStoreError.keychain(updateStatus)
        }
    }

    func readSecret(service: String, account: String) throws -> Data? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw SecretStoreError.dataDecoding
        }
        return data
    }

    func deleteSecret(service: String, account: String) throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
    }

    static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}
