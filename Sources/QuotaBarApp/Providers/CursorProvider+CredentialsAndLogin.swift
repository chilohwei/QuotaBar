import Foundation

extension CursorProvider {
    func updateCurrentCredentials(_ secret: String) async throws {
        let credentials = try credentialsForInstalledTool(from: secret)
        try writeLocalCursorCredentials(credentials)
    }

    func persistRefreshedSecret(_ secret: String, for account: Account, isActive: Bool) async throws {
        _ = isActive
        let encoded = encodeCredentials(try credentialsForInstalledTool(from: secret))
        try writeManagedCredentialsSnapshot(encoded, for: account)
    }

    func deleteAccountArtifacts(account: Account) async throws {
        if let path = account.settings.cursorProfilePath, !path.isEmpty {
            try fileService.removeItemIfExists(at: path)
        }
        let defaultProfilePath = AppPaths.managedCursorProfilePath(accountID: account.id)
        if defaultProfilePath != account.settings.cursorProfilePath {
            try fileService.removeItemIfExists(at: defaultProfilePath)
        }
    }

    func managedCredentialsFilePath(for account: Account) -> String {
        let profilePath = account.settings.cursorProfilePath ?? AppPaths.managedCursorProfilePath(accountID: account.id)
        return "\(profilePath)/credentials.json"
    }

    func writeManagedCredentialsSnapshot(_ encoded: String, for account: Account) throws {
        let credentialsPath = managedCredentialsFilePath(for: account)
        try fileService.createDirectoryIfNeeded(at: URL(fileURLWithPath: credentialsPath).deletingLastPathComponent().path)
        try fileService.writeTextWithBackup(
            encoded,
            to: credentialsPath,
            backupBaseName: "credentials.json",
            permissions: 0o600
        )
    }

    func credentialsForInstalledTool(from secret: String) throws -> CursorCredentials {
        let credentials = try parseCredentials(secret)
        if let stateDatabasePath = credentials.stateDatabasePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stateDatabasePath.isEmpty,
           fileService.fileExists(at: stateDatabasePath) {
            return credentials
        }

        guard let statePath = preferredCursorStateDatabasePath() else {
            return credentials
        }

        return CursorCredentials(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            email: credentials.email,
            membershipType: credentials.membershipType,
            subscriptionStatus: credentials.subscriptionStatus,
            subscriptionPeriodEnd: credentials.subscriptionPeriodEnd,
            stateDatabasePath: fileService.expand(path: statePath),
            source: credentials.source
        )
    }

    func preferredCursorStateDatabasePath() -> String? {
        cursorStateDatabaseCandidates()
            .compactMap(cursorStateCandidateIfExists)
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
            .first?
            .path
    }

    func recoveredSecretMatches(_ secret: String, account: Account) -> Bool {
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        guard let credentials = try? parseCredentials(secret) else {
            return false
        }

        guard let expectedIdentity = account.settings.identityKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedIdentity.isEmpty else {
            if let accountEmail = emailAddress(in: account.name),
               cursorCredentialIdentityCandidates(credentials).contains(normalizeIdentity("cursor:email:\(accountEmail)"))
                || cursorCredentialIdentityCandidates(credentials).contains(normalizeIdentity("cursor:\(accountEmail)")) {
                return true
            }
            return false
        }

        return cursorCredentialIdentityCandidates(credentials).contains(normalizeIdentity(expectedIdentity))
    }
}
