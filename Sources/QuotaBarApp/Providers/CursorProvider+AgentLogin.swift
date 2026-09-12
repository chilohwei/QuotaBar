import Foundation

extension CursorProvider {
    func readKeychainPassword(service: String) throws -> String? {
        // Cursor stores `cursor-access-token` / `cursor-refresh-token` through
        // `/usr/bin/security`, so their decrypt ACL trusts only that binary. A direct
        // Security.framework read from QuotaBar fails closed; delegate to the trusted tool.
        SystemSecretKeychainClient().readGenericPasswordUsingSecurityTool(service: service)
    }

    func cursorEmail(fromAccessToken accessToken: String) -> String? {
        for claim in ["email", "https://cursor.sh/email", "https://cursor.com/email"] {
            if let value = jwtStringClaim(accessToken, claim: claim),
               let email = emailAddress(in: value) {
                return email
            }
        }
        return nil
    }
}
