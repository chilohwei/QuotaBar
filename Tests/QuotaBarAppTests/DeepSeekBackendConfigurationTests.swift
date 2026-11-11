import Foundation
import Testing
@testable import QuotaBarApp

struct DeepSeekBackendConfigurationTests {
    @Test func codexUsesTheSelectedProviderAndItsDeclaredKey() {
        let config = """
            model_provider = "other"
            profile = "work"
            [profiles.work]
            model_provider = "deepseek"
            [model_providers.other]
            base_url = "https://example.com"
            experimental_bearer_token = "sk-unrelated"
            [model_providers.deepseek]
            base_url = "https://api.deepseek.com/v1/" # direct API
            env_key = "DEEPSEEK_API_KEY"
            """
        let env = ["DEEPSEEK_API_KEY": "sk-example"]
        #expect(DeepSeekBackendConfiguration.codex(config, environment: env)?.apiKey == "sk-example")
        #expect(DeepSeekBackendConfiguration.codex(config, environment: [:]) != nil)
        #expect(DeepSeekBackendConfiguration.codex(
            config.replacingOccurrences(of: #"profile = "work""#, with: ""),
            environment: env
        ) == nil)
    }

    @Test func claudeReadsOnlyTheConfiguredOfficialEndpoint() throws {
        func settings(_ url: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "env": ["ANTHROPIC_BASE_URL": url, "ANTHROPIC_AUTH_TOKEN": "sk-example"]
            ])
        }

        let direct = try settings("https://api.deepseek.com/anthropic/")
        #expect(DeepSeekBackendConfiguration.claude(direct, environment: [:])?.apiKey == "sk-example")

        for url in [
            "https://api.deepseek.com.example.com/anthropic",
            "http://api.deepseek.com/anthropic",
            "https://user@api.deepseek.com/anthropic",
            "https://api.deepseek.com:444/anthropic",
            "https://api.deepseek.com/anthropic?relay=1"
        ] {
            let invalid = try settings(url)
            #expect(DeepSeekBackendConfiguration.claude(invalid, environment: [:]) == nil)
        }
    }

    @Test func unusedProvidersAndMultilineTextDoNotCount() {
        let config = """
            model_provider = 'other'
            developer_instructions = '''
            [model_providers.other]
            base_url = "https://api.deepseek.com"
            '''
            [model_providers.deepseek]
            base_url = 'https://api.deepseek.com'
            """
        #expect(DeepSeekBackendConfiguration.codex(config, environment: [:]) == nil)
    }
}
