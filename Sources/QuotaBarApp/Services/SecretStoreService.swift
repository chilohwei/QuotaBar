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

    // @unchecked Sendable: the `claimed` set is only mutated or read under `lock`.
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
    private static let interactionLock = NSLock()

    func saveSecret(_ data: Data, service: String, account: String) throws {
        try Self.withUserInteractionDisabled {
            var query = Self.baseQuery(service: service, account: account)
            query[kSecValueData as String] = data
            Self.applyAccessPolicy(to: &query)

            var addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // Recreate legacy entries instead of updating them. An old ACL may trust only a
                // previous build, so every step remains inside the no-interaction scope.
                let deleteStatus = SecItemDelete(
                    Self.baseQuery(service: service, account: account) as CFDictionary
                )
                guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                    throw SecretStoreError.keychain(deleteStatus)
                }
                addStatus = SecItemAdd(query as CFDictionary, nil)
            }
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.keychain(addStatus)
            }
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
        try readGenericPassword(service: service, account: account)
    }

    /// Reads a generic password without ever permitting SecurityAgent UI. Omitting `account`
    /// matches the first local item for the service, mirroring the providers' previous lookup.
    func readGenericPassword(service: String, account: String? = nil) throws -> Data? {
        try Self.withUserInteractionDisabled {
            try Self.copyGenericPassword(service: service, account: account)
        }
    }

    /// Reads a generic password owned by a CLI tool (Claude Code, Cursor) by delegating to
    /// `/usr/bin/security`. Those items are created with `security add-generic-password`, so
    /// their decrypt ACL trusts ONLY `/usr/bin/security` (with `don't-require-password`) and
    /// carries no on-disk fallback on macOS. QuotaBar's own process is not in that ACL, so a
    /// direct `SecItemCopyMatching` fails closed with errSecAuthFailed /
    /// errSecInteractionNotAllowed and reports the account as signed-out. Delegating the read
    /// to the one binary the item trusts returns the value without ever raising the keychain
    /// authorization dialog. An item QuotaBar has rewritten under the open ACL is likewise
    /// readable this way, so this is safe for every tool-owned item regardless of who last
    /// wrote it.
    func readGenericPasswordUsingSecurityTool(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = String(data: output, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Writes/updates a CLI-owned generic password through `/usr/bin/security`.
    ///
    /// `-U` upserts in place. Do **not** pass `-A`: rewriting the ACL to "allow all apps"
    /// can itself raise a SecurityAgent password dialog, and third-party apps that rely on
    /// Always Allow lose that grant when Claude Code later refreshes the item. QuotaBar never
    /// needs the open ACL — it only reads/writes through `/usr/bin/security`, whose
    /// `apple-tool:` partition matches the item Claude Code creates, so no authorization UI
    /// appears. Direct `SecItemAdd`/`SecItemUpdate` still cannot touch these items.
    func writeGenericPasswordUsingSecurityTool(
        _ password: String,
        service: String,
        account: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password",
            "-U",
            "-s",
            service,
            "-a",
            account,
            "-w",
            password
        ]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw SecretStoreError.keychain(errSecAuthFailed)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SecretStoreError.keychain(errSecAuthFailed)
        }
    }

    /// Compare-and-swap for CLI-owned items: read and write exclusively through
    /// `/usr/bin/security` so ACL-restricted credentials can still be rotated. Returns false
    /// when the live value no longer matches `expected` or the write cannot be verified —
    /// never raises SecurityAgent UI and never throws for a failed swap (callers treat false
    /// as "another maintainer owns this pair; try again later").
    func compareAndSwapGenericPasswordUsingSecurityTool(
        expected: String,
        replacement: String,
        service: String,
        account: String
    ) -> Bool {
        guard let current = readGenericPasswordUsingSecurityTool(service: service),
              current == expected else {
            return false
        }
        do {
            try writeGenericPasswordUsingSecurityTool(
                replacement,
                service: service,
                account: account
            )
        } catch {
            return false
        }
        return readGenericPasswordUsingSecurityTool(service: service) == replacement
    }

    /// Updates an existing item only when it still contains `expected`, then reads it back.
    /// Every operation runs with SecurityAgent UI disabled. Unlike `saveSecret`, this never
    /// deletes and recreates the item, so a failed live-token rotation cannot erase Claude
    /// Code's credential or replace its ACL.
    ///
    /// Prefer `compareAndSwapGenericPasswordUsingSecurityTool` for Claude Code / Cursor items
    /// whose ACL trusts only `/usr/bin/security`; this Security.framework path returns false
    /// for those without throwing.
    func compareAndSwapGenericPassword(
        expected: Data,
        replacement: Data,
        service: String,
        account: String
    ) throws -> Bool {
        try Self.withUserInteractionDisabled {
            guard try Self.copyGenericPassword(service: service, account: account) == expected else {
                return false
            }

            let status = SecItemUpdate(
                Self.updateQuery(service: service, account: account) as CFDictionary,
                [kSecValueData as String: replacement] as CFDictionary
            )
            if status == errSecItemNotFound
                || status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
                || status == errSecUserCanceled {
                return false
            }
            guard status == errSecSuccess else {
                throw SecretStoreError.keychain(status)
            }
            return try Self.copyGenericPassword(service: service, account: account) == replacement
        }
    }

    func deleteSecret(service: String, account: String) throws {
        try Self.withUserInteractionDisabled {
            let status = SecItemDelete(
                Self.baseQuery(service: service, account: account) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.keychain(status)
            }
        }
    }

    static func readQuery(service: String, account: String?) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return query
    }

    static func updateQuery(service: String, account: String) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return query
    }

    static func baseQuery(service: String, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    /// `SecKeychainSetUserInteractionAllowed` is process-global. Serialize every Keychain
    /// operation, disable UI before touching an item, and do not run the operation if either
    /// state query fails. This makes locked or ACL-protected items fail closed.
    private static func withUserInteractionDisabled<T>(
        _ operation: () throws -> T
    ) throws -> T {
        interactionLock.lock()
        defer { interactionLock.unlock() }

        var interactionWasAllowed = DarwinBoolean(false)
        let stateStatus = SecKeychainGetUserInteractionAllowed(&interactionWasAllowed)
        guard stateStatus == errSecSuccess else {
            throw SecretStoreError.keychain(stateStatus)
        }

        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else {
            throw SecretStoreError.keychain(disableStatus)
        }

        let result: Result<T, Error>
        do {
            result = .success(try operation())
        } catch {
            result = .failure(error)
        }

        let restoreStatus = SecKeychainSetUserInteractionAllowed(interactionWasAllowed.boolValue)
        guard restoreStatus == errSecSuccess else {
            throw SecretStoreError.keychain(restoreStatus)
        }
        return try result.get()
    }

    private static func copyGenericPassword(service: String, account: String?) throws -> Data? {
        let query = readQuery(service: service, account: account)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // ACL-restricted CLI items (Claude Code, Cursor) answer errSecAuthFailed when this
        // process is not trusted and UI is disabled — same fail-closed class as
        // errSecInteractionNotAllowed. Treat both as "not readable here" so callers can fall
        // back to `/usr/bin/security` instead of surfacing SecretStoreError to the UI.
        if status == errSecItemNotFound
            || status == errSecInteractionNotAllowed
            || status == errSecAuthFailed {
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
}
