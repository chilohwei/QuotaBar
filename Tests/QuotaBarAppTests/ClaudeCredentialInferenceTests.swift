import Testing
@testable import QuotaBarApp

@Suite("Claude credential inference")
struct ClaudeCredentialInferenceTests {
    @Test("OAuth credentials infer a first-party signed-in account")
    func oauthCredentialsInferFirstPartyLogin() {
        let state = ClaudeCodeProvider().inferredClaudeAuthentication(
            keychainCredentials: #"{"claudeAiOauth":{"accessToken":"access-token"}}"#,
            claudeCredentialsJSON: nil,
            claudeAuthJSON: nil,
            claudeSettingsJSON: nil
        )

        #expect(state.loggedIn)
        #expect(state.authMethod == "oauth")
        #expect(state.apiProvider == "firstParty")
    }

    @Test("settings API token infers the configured provider")
    func settingsTokenInfersConfiguredProvider() {
        let state = ClaudeCodeProvider().inferredClaudeAuthentication(
            keychainCredentials: nil,
            claudeCredentialsJSON: nil,
            claudeAuthJSON: nil,
            claudeSettingsJSON: #"""
            {
              "env": {
                "ANTHROPIC_API_KEY": "api-token",
                "ANTHROPIC_BASE_URL": "https://api.example.com"
              }
            }
            """#
        )

        #expect(state.loggedIn)
        #expect(state.authMethod == "api_key")
        #expect(state.apiProvider == "https://api.example.com")
    }

    @Test("empty credential inputs infer a signed-out account")
    func emptyInputsInferSignedOutAccount() {
        let state = ClaudeCodeProvider().inferredClaudeAuthentication(
            keychainCredentials: nil,
            claudeCredentialsJSON: nil,
            claudeAuthJSON: nil,
            claudeSettingsJSON: nil
        )

        #expect(!state.loggedIn)
        #expect(state.authMethod == nil)
        #expect(state.apiProvider == nil)
    }
}
