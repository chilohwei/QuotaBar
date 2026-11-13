import Testing
@testable import QuotaBarApp

@Suite("Quota notification evaluator")
struct QuotaNotificationEvaluatorTests {
    struct Transition {
        let previous: Double?
        let current: Double?
        let expected: QuotaNotificationEvent?
    }

    @Test("notifications reflect quota transitions and require a valid reading", arguments: [
        Transition(previous: 0.35, current: 0.15, expected: .quotaLow(remainingPercent: 15)),
        Transition(previous: 0.15, current: 0.12, expected: nil),
        Transition(previous: nil, current: 0.15, expected: nil),
        Transition(previous: 0.05, current: 0.0, expected: .quotaExhausted),
        Transition(previous: 0.0, current: 0.0, expected: nil),
        Transition(previous: nil, current: 0.0, expected: nil),
        Transition(previous: 0.0, current: 0.9, expected: .quotaRecovered(remainingPercent: 90)),
        Transition(previous: 0.0, current: 0.05, expected: nil),
        Transition(previous: 0.5, current: 0.9, expected: nil),
        Transition(previous: 0.5, current: nil, expected: nil)
    ])
    func notificationForTransition(transition: Transition) {
        let event = QuotaNotificationEvaluator.event(
            previousRatio: transition.previous,
            currentRatio: transition.current,
            threshold: 0.20
        )
        #expect(event == transition.expected)
    }
}
