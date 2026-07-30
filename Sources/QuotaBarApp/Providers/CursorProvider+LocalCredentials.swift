import Foundation

extension CursorProvider {
    func readLocalCursorCredentials() throws -> String {
        let candidates = cursorStateDatabaseCandidates()
            .compactMap(cursorStateCandidateIfExists)
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })

        guard !candidates.isEmpty else {
            throw ProviderError.loginRequired(tool: .cursor, message: "未找到 Cursor 登录状态，请先打开 Cursor 并登录")
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                return try readLocalCursorCredentials(statePath: candidate.path)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ProviderError.loginRequired(tool: .cursor, message: "未找到 Cursor 登录 token，请先在 Cursor 中登录")
    }

    func readLocalCursorCredentials(statePath: String) throws -> String {
        guard fileService.fileExists(at: statePath) else {
            throw ProviderError.loginRequired(tool: .cursor, message: "未找到 Cursor 登录状态，请先打开 Cursor 并登录")
        }

        let values = try readCursorStateValues(
            keys: [
                "cursorAuth/accessToken",
                "cursorAuth/refreshToken",
                "cursorAuth/cachedEmail",
                "cursorAuth/stripeMembershipType",
                "cursorAuth/stripeSubscriptionStatus",
                "cursorAuth/stripeCurrentPeriodEnd",
                "cursorAuth/subscriptionCurrentPeriodEnd"
            ],
            requiredKeys: ["cursorAuth/accessToken"],
            statePath: statePath
        )
        let accessToken = values["cursorAuth/accessToken"]
        guard let accessToken, !accessToken.isEmpty else {
            throw ProviderError.loginRequired(tool: .cursor, message: "未找到 Cursor 登录 token，请先在 Cursor 中登录")
        }

        let credentials = CursorCredentials(
            accessToken: accessToken,
            refreshToken: values["cursorAuth/refreshToken"],
            email: values["cursorAuth/cachedEmail"],
            membershipType: values["cursorAuth/stripeMembershipType"],
            subscriptionStatus: values["cursorAuth/stripeSubscriptionStatus"],
            subscriptionPeriodEnd: parseDate(values["cursorAuth/stripeCurrentPeriodEnd"] ?? values["cursorAuth/subscriptionCurrentPeriodEnd"] ?? ""),
            stateDatabasePath: fileService.expand(path: statePath),
            source: "cursorDesktopState"
        )
        return encodeCredentials(credentials)
    }

    func writeLocalCursorCredentials(_ credentials: CursorCredentials) throws {
        let preferredPath = credentials.stateDatabasePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = cursorStateDatabaseCandidates()
            .compactMap(cursorStateCandidateIfExists)
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })

        let targetPath: String?
        if let preferredPath,
           fileService.fileExists(at: preferredPath) {
            targetPath = preferredPath
        } else {
            targetPath = candidates.first?.path
        }

        guard let targetPath else {
            throw ProviderError.loginRequired(tool: .cursor, message: "未找到 Cursor 登录状态，请先打开 Cursor 并登录一次")
        }

        let email = cursorAccountEmail(from: credentials)
        var upserts: [String: String] = [
            "cursorAuth/accessToken": credentials.accessToken
        ]
        if let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshToken.isEmpty {
            upserts["cursorAuth/refreshToken"] = refreshToken
        }
        if let email {
            upserts["cursorAuth/cachedEmail"] = email
        }
        if let membershipType = credentials.membershipType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !membershipType.isEmpty {
            upserts["cursorAuth/stripeMembershipType"] = membershipType
        }
        if let subscriptionStatus = credentials.subscriptionStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subscriptionStatus.isEmpty {
            upserts["cursorAuth/stripeSubscriptionStatus"] = subscriptionStatus
        }
        if let subscriptionPeriodEnd = credentials.subscriptionPeriodEnd {
            upserts["cursorAuth/stripeCurrentPeriodEnd"] = ISO8601DateFormatter().string(from: subscriptionPeriodEnd)
            upserts["cursorAuth/subscriptionCurrentPeriodEnd"] = ISO8601DateFormatter().string(from: subscriptionPeriodEnd)
        }

        let deleteKeys = [
            credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ? "cursorAuth/refreshToken" : nil,
            email == nil ? "cursorAuth/cachedEmail" : nil,
            credentials.membershipType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ? "cursorAuth/stripeMembershipType" : nil,
            credentials.subscriptionStatus?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ? "cursorAuth/stripeSubscriptionStatus" : nil,
            credentials.subscriptionPeriodEnd == nil ? "cursorAuth/stripeCurrentPeriodEnd" : nil,
            credentials.subscriptionPeriodEnd == nil ? "cursorAuth/subscriptionCurrentPeriodEnd" : nil
        ].compactMap { $0 }

        try updateCursorStateDatabase(
            statePath: targetPath,
            upserts: upserts,
            deleteKeys: deleteKeys
        )
    }

    func readCursorAgentCredentials() throws -> String? {
        guard let accessToken = try readKeychainPassword(service: "cursor-access-token"),
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let credentials = CursorCredentials(
            accessToken: accessToken,
            refreshToken: try readKeychainPassword(service: "cursor-refresh-token"),
            email: cursorEmail(fromAccessToken: accessToken),
            membershipType: nil,
            subscriptionStatus: nil,
            subscriptionPeriodEnd: nil,
            stateDatabasePath: nil,
            source: "cursorAgentKeychain"
        )
        return encodeCredentials(credentials)
    }

    func cursorStateDatabaseCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Cursor - Insiders/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Cursor Nightly/User/globalStorage/state.vscdb"
        ]
    }

    func cursorStateCandidateIfExists(path: String) -> CursorStateCandidate? {
        let expanded = fileService.expand(path: path)
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: expanded)
        let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
        return CursorStateCandidate(path: path, modifiedAt: modifiedAt)
    }

    func cursorAccountEmail(from credentials: CursorCredentials) -> String? {
        if let email = cursorEmail(fromAccessToken: credentials.accessToken) {
            return email
        }
        if let email = credentials.email,
           let normalized = emailAddress(in: email) {
            return normalized
        }
        return nil
    }

    func cursorCredentialIdentityCandidates(_ credentials: CursorCredentials) -> Set<String> {
        var candidates = Set<String>()
        if let subject = jwtStringClaim(credentials.accessToken, claim: "sub")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subject.isEmpty {
            candidates.insert(normalizeIdentity("cursor:sub:\(subject.lowercased())"))
            candidates.insert(normalizeIdentity("cursor:\(subject)"))
        }
        if let email = cursorAccountEmail(from: credentials) {
            candidates.insert(normalizeIdentity("cursor:email:\(email)"))
            candidates.insert(normalizeIdentity("cursor:\(email)"))
        }
        if let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshToken.isEmpty {
            candidates.insert(normalizeIdentity("cursor:refresh:\(refreshToken.suffix(16))"))
            candidates.insert(normalizeIdentity("cursor:\(refreshToken.suffix(16))"))
        }
        candidates.insert(normalizeIdentity("cursor:token:\(credentials.accessToken.suffix(16))"))
        candidates.insert(normalizeIdentity("cursor:\(credentials.accessToken.suffix(16))"))
        return candidates
    }

    func uniqueIdentityAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        return aliases.filter { alias in
            seen.insert(normalizeIdentity(alias)).inserted
        }
    }

    func validateCursorCredentialsMatchAccount(_ credentials: CursorCredentials, account: Account) throws {
        guard let expectedIdentity = account.settings.identityKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedIdentity.isEmpty else {
            return
        }

        guard cursorCredentialIdentityCandidates(credentials).contains(normalizeIdentity(expectedIdentity)) else {
            throw ProviderError.network("Cursor 凭据与当前账号不一致，请重新登录或重新添加该账号")
        }
    }

    func emailAddress(in text: String) -> String? {
        let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange]).lowercased()
    }
}
