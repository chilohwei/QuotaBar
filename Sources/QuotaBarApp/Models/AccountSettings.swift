import Foundation

struct AccountSettings: Codable, Equatable, Sendable {
    var codexHomePath: String?
    var codexRegistryKey: String?
    var cursorProfilePath: String?
    var identityKey: String?

    static let empty = AccountSettings(
        codexHomePath: nil,
        codexRegistryKey: nil,
        cursorProfilePath: nil,
        identityKey: nil
    )
}
