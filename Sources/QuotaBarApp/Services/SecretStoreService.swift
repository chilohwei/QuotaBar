import Foundation
import Darwin
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
            migrateAccessPolicyIfNeeded(secret: secret, accountKey: accountKey)
            return secret
        }

        if let legacySecret = try loadLegacyStore()[accountKey] {
            try saveSecret(legacySecret, accountKey: accountKey)
            return legacySecret
        }

        throw SecretStoreError.missingData
    }

    /// Items saved by builds before the any-application ACL fix trust only the exact binary
    /// that stored them, so every ad-hoc-signed update triggered the keychain password dialog
    /// on first read. Once a read has succeeded (the user granted access one final time),
    /// rewrite the item under the corrected policy so no future build ever prompts again.
    /// Once per key per launch — the rewrite is a delete+add, no reason to churn on
    /// every refresh.
    private func migrateAccessPolicyIfNeeded(secret: String, accountKey: String) {
        let migrationKey = "\(keychainService)\u{1F}\(accountKey)"
        guard Self.aclMigrationRegistry.claim(migrationKey) else { return }
        try? saveSecret(secret, accountKey: accountKey)
    }

    private static let aclMigrationRegistry = ACLMigrationRegistry()

    private final class ACLMigrationRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed: Set<String> = []

        /// Returns true exactly once per key for the lifetime of the process.
        func claim(_ key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return claimed.insert(key).inserted
        }
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
    private typealias SecAccessCreateFunction = @convention(c) (
        CFString,
        CFArray?,
        UnsafeMutablePointer<SecAccess?>?
    ) -> OSStatus
    private typealias SecAccessCopyACLListFunction = @convention(c) (
        SecAccess,
        UnsafeMutablePointer<CFArray?>?
    ) -> OSStatus
    private typealias SecACLCopyContentsFunction = @convention(c) (
        SecACL,
        UnsafeMutablePointer<CFArray?>?,
        UnsafeMutablePointer<CFString?>?,
        UnsafeMutablePointer<UInt16>?
    ) -> OSStatus
    private typealias SecACLSetContentsFunction = @convention(c) (
        SecACL,
        CFArray?,
        CFString,
        UInt16
    ) -> OSStatus
    private typealias SecKeychainItemCopyAccessFunction = @convention(c) (
        SecKeychainItem,
        UnsafeMutablePointer<SecAccess?>?
    ) -> OSStatus
    private typealias SecACLCopyAuthorizationsFunction = @convention(c) (
        SecACL
    ) -> Unmanaged<CFArray>?

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
        // CAUTION on the legacy API's asymmetric NULL semantics: for `SecAccessCreate` a NULL
        // trusted-application list means "trust ONLY the calling binary" (the bug that made
        // every ad-hoc-signed update re-prompt), while for `SecACLSetContents` a NULL list
        // means "any application". Creating the access object is therefore only step one;
        // the ACL entries must then be rewritten to drop the calling-binary restriction and
        // the password-confirmation prompt selector.
        var access: SecAccess?
        if legacySecAccessCreate("QuotaBar" as CFString, trustedApplications: nil, access: &access) == errSecSuccess,
           let access,
           openACLToAllApplications(access) {
            query[kSecAttrAccess as String] = access
        } else {
            // Fall back to the data-protection accessibility class if the legacy ACL
            // API is unavailable. Still device-only and after-first-unlock.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    /// Rewrites every ACL entry of `access` to allow any application without a confirmation
    /// prompt (application list NULL + prompt selector 0). Entries that refuse the edit (the
    /// owner/change-ACL entry can) are skipped — the decrypt entry is the one that gates
    /// reads. Returns true when at least one entry was opened.
    private static func openACLToAllApplications(_ access: SecAccess) -> Bool {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            return false
        }
        defer { dlclose(handle) }
        guard let copyListSymbol = dlsym(handle, "SecAccessCopyACLList"),
              let copyContentsSymbol = dlsym(handle, "SecACLCopyContents"),
              let setContentsSymbol = dlsym(handle, "SecACLSetContents") else {
            return false
        }
        let copyACLList = unsafeBitCast(copyListSymbol, to: SecAccessCopyACLListFunction.self)
        let copyContents = unsafeBitCast(copyContentsSymbol, to: SecACLCopyContentsFunction.self)
        let setContents = unsafeBitCast(setContentsSymbol, to: SecACLSetContentsFunction.self)

        var listRef: CFArray?
        guard copyACLList(access, &listRef) == errSecSuccess, let list = listRef else {
            return false
        }

        var openedAny = false
        for index in 0 ..< CFArrayGetCount(list) {
            let acl = unsafeBitCast(CFArrayGetValueAtIndex(list, index), to: SecACL.self)
            var applications: CFArray?
            var description: CFString?
            var promptSelector: UInt16 = 0
            guard copyContents(acl, &applications, &description, &promptSelector) == errSecSuccess else {
                continue
            }
            if setContents(acl, nil, description ?? ("QuotaBar" as CFString), 0) == errSecSuccess {
                openedAny = true
            }
        }
        return openedAny
    }

    private static func legacySecAccessCreate(
        _ descriptor: CFString,
        trustedApplications: CFArray?,
        access: UnsafeMutablePointer<SecAccess?>?
    ) -> OSStatus {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            return errSecUnimplemented
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "SecAccessCreate") else {
            return errSecUnimplemented
        }
        let createAccess = unsafeBitCast(symbol, to: SecAccessCreateFunction.self)
        return createAccess(descriptor, trustedApplications, access)
    }

    func readSecret(service: String, account: String) throws -> Data? {
        // Reading the payload of an item whose ACL trusts only a previous build's code
        // signature raises the macOS keychain password dialog, and neither
        // kSecUseAuthenticationUISkip nor any other query key suppresses that legacy prompt.
        // The ACL itself, however, is readable silently — so inspect it first, and if this
        // item would prompt, report "not found" WITHOUT touching the payload. The caller then
        // re-imports the credential from its source and re-saves it under the open policy.
        // Items that cannot be re-imported (accounts detached from their tool) surface the
        // ordinary re-add message instead of an authorization dialog.
        if Self.itemWouldPromptOnRead(service: service, account: account) {
            return nil
        }

        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

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

    /// True when decrypting this item would raise the keychain authorization dialog for the
    /// current (differently-signed) build: its ACL has no decrypt entry that allows any
    /// application without confirmation. ACL metadata is readable without authorization, so
    /// this check itself never prompts. Items that cannot be inspected (missing, or the
    /// legacy ACL API is unavailable) are reported as safe — the read path then falls back
    /// to its own non-interactive error handling.
    private static func itemWouldPromptOnRead(service: String, account: String) -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnRef as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let itemRef = result else {
            return false
        }

        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            return false
        }
        defer { dlclose(handle) }
        guard let copyAccessSymbol = dlsym(handle, "SecKeychainItemCopyAccess"),
              let copyListSymbol = dlsym(handle, "SecAccessCopyACLList"),
              let copyAuthorizationsSymbol = dlsym(handle, "SecACLCopyAuthorizations"),
              let copyContentsSymbol = dlsym(handle, "SecACLCopyContents") else {
            return false
        }
        let copyAccess = unsafeBitCast(copyAccessSymbol, to: SecKeychainItemCopyAccessFunction.self)
        let copyACLList = unsafeBitCast(copyListSymbol, to: SecAccessCopyACLListFunction.self)
        let copyAuthorizations = unsafeBitCast(copyAuthorizationsSymbol, to: SecACLCopyAuthorizationsFunction.self)
        let copyContents = unsafeBitCast(copyContentsSymbol, to: SecACLCopyContentsFunction.self)

        let item = unsafeBitCast(itemRef, to: SecKeychainItem.self)
        var access: SecAccess?
        guard copyAccess(item, &access) == errSecSuccess, let access else {
            // No legacy ACL to inspect (e.g. a data-protection item) — nothing that would
            // raise the legacy dialog.
            return false
        }
        var listRef: CFArray?
        guard copyACLList(access, &listRef) == errSecSuccess, let list = listRef else {
            return false
        }

        for index in 0 ..< CFArrayGetCount(list) {
            let acl = unsafeBitCast(CFArrayGetValueAtIndex(list, index), to: SecACL.self)
            guard let authorizations = copyAuthorizations(acl)?.takeRetainedValue() as? [CFString] else {
                continue
            }
            let tags = Set(authorizations.map { $0 as String })
            guard tags.contains("ACLAuthorizationDecrypt") || tags.contains("ACLAuthorizationAny") else {
                continue
            }
            var applications: CFArray?
            var description: CFString?
            var promptSelector: UInt16 = 0
            guard copyContents(acl, &applications, &description, &promptSelector) == errSecSuccess else {
                continue
            }
            // A nil application list in ACL *contents* means "any application"; a zero prompt
            // selector means no confirmation dialog. Such an entry makes reads silent.
            if applications == nil && promptSelector == 0 {
                return false
            }
        }
        return true
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
