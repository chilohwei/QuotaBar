import Foundation
import Security

enum SecretStoreError: LocalizedError {
    case dataEncoding
    case dataDecoding
    case keychain(OSStatus)
    case missingData

    var errorDescription: String? {
        switch self {
        case .dataEncoding, .dataDecoding, .keychain, .missingData:
            return "登录信息异常，请删除后重新添加"
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
        Self.applyAccessPolicy(to: &query)

        var addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Replace instead of SecItemUpdate. The existing item may have been
            // created by a different build of QuotaBar (ad-hoc signing gives every
            // build a distinct code signature), so it is guarded by an ACL that
            // trusts only that old signature. Reading or updating it would raise the
            // macOS keychain password prompt. SecItemDelete is not gated by that ACL,
            // so delete-then-add rewrites the item with the unrestricted access
            // policy below — silently migrating legacy entries and never prompting.
            SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
            addStatus = SecItemAdd(query as CFDictionary, nil)
        }
        guard addStatus == errSecSuccess else {
            throw SecretStoreError.keychain(addStatus)
        }
    }

    /// Attaches an access policy that lets any application on this Mac read the item
    /// without an authorization prompt (the "Allow all applications to access this
    /// item" option in Keychain Access). Without it, the item's ACL trusts only the
    /// exact binary that stored it, so a rebuilt or updated QuotaBar — which has a
    /// different code signature — triggers the keychain password dialog on every
    /// read. The stored tokens are imported from the tools' own local files (which
    /// are protected by nothing stronger than user file permissions), so an
    /// unrestricted-but-still-encrypted keychain item is no weaker than the source.
    private static func applyAccessPolicy(to query: inout [String: Any]) {
        var access: SecAccess?
        // A nil trusted-application list means "all applications", i.e. no prompt.
        if SecAccessCreate("QuotaBar" as CFString, nil, &access) == errSecSuccess,
           let access {
            query[kSecAttrAccess as String] = access
        } else {
            // Fall back to the data-protection accessibility class if the legacy ACL
            // API is unavailable. Still device-only and after-first-unlock.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    func readSecret(service: String, account: String) throws -> Data? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        // Never let a keychain ACL mismatch raise the interactive password dialog.
        // An item stored by a previous, differently-signed build of QuotaBar is
        // guarded by an ACL that trusts only that old signature, so reading it would
        // normally prompt for the macOS login password. Disabling keychain UI for
        // the read makes it return errSecInteractionNotAllowed instead; we treat
        // that as "not found" so the caller re-imports the credential from source
        // and re-saves it with the unrestricted access policy (no prompt).
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed {
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
