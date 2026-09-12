import CoreGraphics
import Foundation
import IOKit.ps

struct RefreshIntervalPolicy {
    static let jitterInterval: TimeInterval = 30

    let defaultInterval: TimeInterval
    let lowQuotaInterval: TimeInterval
    let powerSavingInterval: TimeInterval
    let lowQuotaThreshold: Double
    let idlePowerSavingThreshold: TimeInterval

    private let isOnBatteryPowerProvider: () -> Bool
    private let userIdleDurationProvider: () -> TimeInterval

    init(
        defaultInterval: TimeInterval = 150,
        lowQuotaInterval: TimeInterval = 75,
        powerSavingInterval: TimeInterval = 7.5 * 60,
        lowQuotaThreshold: Double = 0.20,
        idlePowerSavingThreshold: TimeInterval = 5 * 60,
        isOnBatteryPower: @escaping () -> Bool = Self.isOnBatteryPower,
        userIdleDuration: @escaping () -> TimeInterval = Self.userIdleDuration
    ) {
        self.defaultInterval = defaultInterval
        self.lowQuotaInterval = lowQuotaInterval
        self.powerSavingInterval = powerSavingInterval
        self.lowQuotaThreshold = lowQuotaThreshold
        self.idlePowerSavingThreshold = idlePowerSavingThreshold
        isOnBatteryPowerProvider = isOnBatteryPower
        userIdleDurationProvider = userIdleDuration
    }

    func automaticRefreshInterval(activeRemainingRatios: [Double]) -> TimeInterval {
        if shouldUsePowerSavingRefreshInterval {
            return powerSavingInterval
        }
        if activeRemainingRatios.contains(where: { $0 < lowQuotaThreshold }) {
            return lowQuotaInterval
        }
        return defaultInterval
    }

    private var shouldUsePowerSavingRefreshInterval: Bool {
        isOnBatteryPowerProvider() && userIdleDurationProvider() >= idlePowerSavingThreshold
    }

    private static func isOnBatteryPower() -> Bool {
        guard let powerSourceInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSources = IOPSCopyPowerSourcesList(powerSourceInfo)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }

        for source in powerSources {
            guard let description = IOPSGetPowerSourceDescription(powerSourceInfo, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey as String] as? String else {
                continue
            }
            if state == kIOPSBatteryPowerValue {
                return true
            }
        }
        return false
    }

    private static func userIdleDuration() -> TimeInterval {
        let eventTypes: [CGEventType] = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .mouseMoved,
            .scrollWheel
        ]
        return eventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }
}
