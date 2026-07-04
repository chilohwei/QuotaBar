import Foundation
import UserNotifications

@MainActor
final class QuotaNotificationService {
    // UNUserNotificationCenter crashes outside a real .app bundle (e.g. `swift run`, tests).
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private var hasRequestedAuthorization = false

    func requestAuthorizationIfNeeded() {
        guard Self.isSupported, !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.app.error("Notification authorization failed: \(String(describing: error), privacy: .private)")
            } else {
                AppLog.app.info("Notification authorization granted: \(granted, privacy: .public)")
            }
        }
    }

    func post(identifier: String, title: String, body: String) {
        guard Self.isSupported else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.app.error("Notification delivery failed: \(String(describing: error), privacy: .private)")
            }
        }
    }
}

// Pure threshold-crossing logic, separated from delivery so it can be unit-tested.
enum QuotaNotificationEvent: Equatable {
    case quotaLow(remainingPercent: Int)
    case quotaExhausted
    case quotaRecovered(remainingPercent: Int)
}

enum QuotaNotificationEvaluator {
    static let exhaustedRatio = 0.001
    static let recoveredRatio = 0.10

    static func event(
        previousRatio: Double?,
        currentRatio: Double?,
        threshold: Double
    ) -> QuotaNotificationEvent? {
        guard let currentRatio else { return nil }
        let percent = Int((currentRatio * 100).rounded())

        if currentRatio <= exhaustedRatio {
            guard let previousRatio, previousRatio > exhaustedRatio else {
                // Only notify on the transition into exhausted, and only when we
                // had a previous reading to compare against (avoids launch spam).
                return nil
            }
            return .quotaExhausted
        }

        if let previousRatio, previousRatio <= exhaustedRatio, currentRatio >= recoveredRatio {
            return .quotaRecovered(remainingPercent: percent)
        }

        if currentRatio <= threshold {
            guard let previousRatio, previousRatio > threshold else { return nil }
            return .quotaLow(remainingPercent: percent)
        }

        return nil
    }
}
