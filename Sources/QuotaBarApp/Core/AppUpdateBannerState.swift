import Foundation

enum AppUpdateBannerState: Equatable {
    case idle
    case checking
    case available(version: String)
    case downloading(progress: Double?)
    case installing
}
