import Foundation

/// Represents the UI state of an offline region during installation or general availability.
enum OfflineRegionStatus: String, Codable, Sendable, Equatable {
    case available
    case installing
    case validating
    case installed
    case updateAvailable
    case failed
    case removing
}
