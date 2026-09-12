import Foundation

enum CodexRegistrySchema {
    static let currentVersion = 3
}

struct CodexRegistryDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var activeAccountKey: String?
    var activeAccountActivatedAtMs: Int64?
    var autoSwitch: CodexAutoSwitchConfig
    var api: CodexAPIConfig
    var accounts: [CodexRegistryAccount]
    var extraFields: [String: JSONValue] = [:]

    static let empty = CodexRegistryDocument(
        schemaVersion: CodexRegistrySchema.currentVersion,
        activeAccountKey: nil,
        activeAccountActivatedAtMs: nil,
        autoSwitch: CodexAutoSwitchConfig(),
        api: CodexAPIConfig(),
        accounts: []
    )

    private enum KnownKey: String, CaseIterable {
        case schemaVersion = "schema_version"
        case activeAccountKey = "active_account_key"
        case activeAccountActivatedAtMs = "active_account_activated_at_ms"
        case autoSwitch = "auto_switch"
        case api
        case accounts
    }

    init(
        schemaVersion: Int,
        activeAccountKey: String?,
        activeAccountActivatedAtMs: Int64?,
        autoSwitch: CodexAutoSwitchConfig,
        api: CodexAPIConfig,
        accounts: [CodexRegistryAccount],
        extraFields: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.activeAccountKey = activeAccountKey
        self.activeAccountActivatedAtMs = activeAccountActivatedAtMs
        self.autoSwitch = autoSwitch
        self.api = api
        self.accounts = accounts
        self.extraFields = extraFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .init(KnownKey.schemaVersion.rawValue))
            ?? CodexRegistrySchema.currentVersion
        activeAccountKey = try container.decodeIfPresent(String.self, forKey: .init(KnownKey.activeAccountKey.rawValue))
        activeAccountActivatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .init(KnownKey.activeAccountActivatedAtMs.rawValue))
        autoSwitch = try container.decodeIfPresent(CodexAutoSwitchConfig.self, forKey: .init(KnownKey.autoSwitch.rawValue))
            ?? CodexAutoSwitchConfig()
        api = try container.decodeIfPresent(CodexAPIConfig.self, forKey: .init(KnownKey.api.rawValue))
            ?? CodexAPIConfig()
        let lossyAccounts = try container.decodeIfPresent(
            [LossyCodexRegistryAccount].self,
            forKey: .init(KnownKey.accounts.rawValue)
        ) ?? []
        accounts = lossyAccounts.compactMap(\.account)

        let knownKeys = Set(KnownKey.allCases.map(\.rawValue))
        extraFields = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            extraFields[key.stringValue] = try? container.decode(JSONValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extraFields {
            try container.encode(value, forKey: .init(key))
        }
        try container.encode(CodexRegistrySchema.currentVersion, forKey: .init(KnownKey.schemaVersion.rawValue))
        try container.encodeIfPresent(activeAccountKey, forKey: .init(KnownKey.activeAccountKey.rawValue))
        try container.encodeIfPresent(activeAccountActivatedAtMs, forKey: .init(KnownKey.activeAccountActivatedAtMs.rawValue))
        try container.encode(autoSwitch, forKey: .init(KnownKey.autoSwitch.rawValue))
        try container.encode(api, forKey: .init(KnownKey.api.rawValue))
        try container.encode(accounts, forKey: .init(KnownKey.accounts.rawValue))
    }
}

struct CodexAutoSwitchConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var threshold5hPercent: Int = 10
    var thresholdWeeklyPercent: Int = 5

    enum CodingKeys: String, CodingKey {
        case enabled
        case threshold5hPercent = "threshold_5h_percent"
        case thresholdWeeklyPercent = "threshold_weekly_percent"
    }
}

struct CodexAPIConfig: Codable, Equatable, Sendable {
    var usage: Bool = true
    var account: Bool = true
}

struct CodexRegistryAccount: Codable, Equatable, Sendable {
    var accountKey: String?
    var chatGPTAccountID: String?
    var chatGPTUserID: String?
    var email: String?
    var alias: String?
    var accountName: String?
    var plan: String?
    var authMode: String?
    var createdAt: Int64?
    var lastUsedAt: Int64?
    var lastUsage: CodexStoredUsageSnapshot?
    var lastUsageAt: Int64?
    var extraFields: [String: JSONValue] = [:]

    var displayName: String {
        [
            alias,
            accountName,
            email
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? accountKey ?? "Codex"
    }

    var resolvedPlan: String? {
        lastUsage?.planType ?? plan
    }

    init(accountKey: String? = nil) {
        self.accountKey = accountKey
    }

    private enum KnownKey: String, CaseIterable {
        case accountKey = "account_key"
        case chatGPTAccountID = "chatgpt_account_id"
        case chatGPTUserID = "chatgpt_user_id"
        case email
        case alias
        case accountName = "account_name"
        case plan
        case authMode = "auth_mode"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case lastUsage = "last_usage"
        case lastUsageAt = "last_usage_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        accountKey = try container.decodeIfPresent(String.self, forKey: .init(KnownKey.accountKey.rawValue))
        chatGPTAccountID = try container.decodeIfPresent(String.self, forKey: .init(KnownKey.chatGPTAccountID.rawValue))
        chatGPTUserID = try container.decodeIfPresent(String.self, forKey: .init(KnownKey.chatGPTUserID.rawValue))
        email = try container.decodeIfPresent(String.self, forKey: .init(KnownKey.email.rawValue))
        alias = try container.decodeIfPresent(String.self, forKey: .init(KnownKey.alias.rawValue))
        accountName = try container.decodeIfPresent(String.self, forKey: .init(KnownKey.accountName.rawValue))
        plan = try container.decodeIfPresent(String.self, forKey: .init(KnownKey.plan.rawValue))
        authMode = try container.decodeIfPresent(String.self, forKey: .init(KnownKey.authMode.rawValue))
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .init(KnownKey.createdAt.rawValue))
        lastUsedAt = try container.decodeIfPresent(Int64.self, forKey: .init(KnownKey.lastUsedAt.rawValue))
        lastUsage = try container.decodeIfPresent(CodexStoredUsageSnapshot.self, forKey: .init(KnownKey.lastUsage.rawValue))
        lastUsageAt = try container.decodeIfPresent(Int64.self, forKey: .init(KnownKey.lastUsageAt.rawValue))

        let knownKeys = Set(KnownKey.allCases.map(\.rawValue))
        extraFields = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            extraFields[key.stringValue] = try? container.decode(JSONValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extraFields {
            try container.encode(value, forKey: .init(key))
        }
        try container.encodeIfPresent(accountKey, forKey: .init(KnownKey.accountKey.rawValue))
        try container.encodeIfPresent(chatGPTAccountID, forKey: .init(KnownKey.chatGPTAccountID.rawValue))
        try container.encodeIfPresent(chatGPTUserID, forKey: .init(KnownKey.chatGPTUserID.rawValue))
        try container.encodeIfPresent(email, forKey: .init(KnownKey.email.rawValue))
        try container.encodeIfPresent(alias, forKey: .init(KnownKey.alias.rawValue))
        try container.encodeIfPresent(accountName, forKey: .init(KnownKey.accountName.rawValue))
        try container.encodeIfPresent(plan, forKey: .init(KnownKey.plan.rawValue))
        try container.encodeIfPresent(authMode, forKey: .init(KnownKey.authMode.rawValue))
        try container.encodeIfPresent(createdAt, forKey: .init(KnownKey.createdAt.rawValue))
        try container.encodeIfPresent(lastUsedAt, forKey: .init(KnownKey.lastUsedAt.rawValue))
        try container.encodeIfPresent(lastUsage, forKey: .init(KnownKey.lastUsage.rawValue))
        try container.encodeIfPresent(lastUsageAt, forKey: .init(KnownKey.lastUsageAt.rawValue))
    }
}

private struct LossyCodexRegistryAccount: Decodable {
    let account: CodexRegistryAccount?

    init(from decoder: Decoder) throws {
        account = try? CodexRegistryAccount(from: decoder)
    }
}

struct CodexStoredUsageWindow: Codable, Equatable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

struct CodexStoredCreditsSnapshot: Codable, Equatable, Sendable {
    var hasCredits: Bool?
    var unlimited: Bool?
    var balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

struct CodexStoredUsageSnapshot: Codable, Equatable, Sendable {
    var primary: CodexStoredUsageWindow?
    var secondary: CodexStoredUsageWindow?
    var credits: CodexStoredCreditsSnapshot?
    var planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case credits
        case planType = "plan_type"
    }

    init(
        primary: CodexStoredUsageWindow? = nil,
        secondary: CodexStoredUsageWindow? = nil,
        credits: CodexStoredCreditsSnapshot? = nil,
        planType: String? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.planType = planType
    }

    init(snapshot: QuotaSnapshot) {
        primary = snapshot.primary.map { CodexStoredUsageWindow(window: $0) }
        secondary = snapshot.secondary.map { CodexStoredUsageWindow(window: $0) }
        if let creditsRemaining = snapshot.creditsRemaining {
            credits = CodexStoredCreditsSnapshot(
                hasCredits: creditsRemaining > 0,
                unlimited: false,
                balance: cleanNumberString(creditsRemaining)
            )
        } else {
            credits = nil
        }
        planType = codexPlanType(from: snapshot.planName)
    }
}

private extension CodexStoredUsageWindow {
    init(window: QuotaWindow) {
        usedPercent = min(max(window.usagePercent * 100, 0), 100)
        windowMinutes = Self.windowMinutes(for: window.label)
        resetsAt = window.resetAt.map { Int64($0.timeIntervalSince1970) }
    }

    static func windowMinutes(for label: String) -> Int? {
        let lower = label.lowercased()
        if lower.contains("5") || lower.contains("300") {
            return 300
        }
        if lower.contains("week") || lower.contains("weekly") || lower.contains("10080") || lower.contains("周") {
            return 10_080
        }
        return nil
    }
}

private func codexPlanType(from rawPlan: String?) -> String? {
    guard let rawPlan = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawPlan.isEmpty else {
        return nil
    }
    let lower = rawPlan.lowercased()
    if lower.contains("enterprise") { return "enterprise" }
    if lower.contains("team") || lower.contains("business") { return "team" }
    if lower.contains("pro lite") || lower.contains("prolite") { return "prolite" }
    if lower.contains("pro") { return "pro" }
    if lower.contains("plus") { return "plus" }
    if lower.contains("free") { return "free" }
    if lower.contains("edu") { return "edu" }
    return "unknown"
}

private func cleanNumberString(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int64(value))
    }
    return String(value)
}

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func firstString(keys: Set<String>) -> String? {
        for key in keys {
            guard let value = self[key] else { continue }
            if let string = value.stringValue {
                return string
            }
        }
        return nil
    }
}

private extension JSONValue {
    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return "\(value)"
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array, .null:
            return nil
        }
    }
}

struct DynamicCodingKey: CodingKey, Sendable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
