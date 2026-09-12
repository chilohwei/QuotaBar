import Foundation

enum LoginMethod: Equatable, Sendable {
    case browser
    case deviceCode
}

/// Shared live state for an in-flight browser/device-code sign-in, so the panel can show
/// which method is running, how long is left, and offer to reopen the authorization page.
/// Providers publish into it from their login flows; `AppState` clears it when the add
/// operation finishes for any reason.
@MainActor
final class LoginFlowProgress: ObservableObject {
    static let shared = LoginFlowProgress()

    @Published private(set) var method: LoginMethod?
    @Published private(set) var deadline: Date?
    @Published private(set) var canReopenAuthorizationPage = false

    private var reopenAction: (() -> Void)?

    func begin(method: LoginMethod?, timeout: TimeInterval?, reopen: (() -> Void)? = nil) {
        self.method = method
        deadline = timeout.map { Date().addingTimeInterval($0) }
        reopenAction = reopen
        canReopenAuthorizationPage = reopen != nil
    }

    func setReopenAction(_ action: (() -> Void)?) {
        reopenAction = action
        canReopenAuthorizationPage = action != nil
    }

    func end() {
        method = nil
        deadline = nil
        reopenAction = nil
        canReopenAuthorizationPage = false
    }

    func reopenAuthorizationPage() {
        reopenAction?()
    }
}
