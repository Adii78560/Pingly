import Foundation
import CoreLocation

// MARK: - Routing Error
enum RoutingError: Error, LocalizedError {
    case routingDataUnavailable
    case regionUnavailable
    case originNodeNotFound
    case destinationNodeNotFound
    case noRouteFound
    case invalidGraph
    case databaseError(String)
    
    var errorDescription: String? {
        switch self {
        case .routingDataUnavailable: return "Offline routing data is not available."
        case .regionUnavailable: return "The requested coordinates are outside the downloaded routing region."
        case .originNodeNotFound: return "Could not find a valid road near the origin."
        case .destinationNodeNotFound: return "Could not find a valid road near the destination."
        case .noRouteFound: return "No valid path connects the origin and destination."
        case .invalidGraph: return "The routing graph is malformed or corrupted."
        case .databaseError(let msg): return "Database error: \(msg)"
        }
    }
}

// MARK: - Domain Models
struct RoadNode: Equatable, Sendable {
    let id: Int64
    let coordinate: CLLocationCoordinate2D
    
    static func == (lhs: RoadNode, rhs: RoadNode) -> Bool {
        return lhs.id == rhs.id
    }
}

struct RoadEdge: Equatable, Sendable {
    let edgeID: Int64
    let osmWayID: Int64
    let sourceNodeID: Int64
    let destinationNodeID: Int64
    let lengthMeters: Double
    let speedKPH: Double
    let roadClass: String
    let name: String?
    let isOneway: Bool
    
    static func == (lhs: RoadEdge, rhs: RoadEdge) -> Bool {
        return lhs.edgeID == rhs.edgeID
    }
}

struct Route: Sendable {
    let origin: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D
    let totalDistanceMeters: Double
    let estimatedTravelTimeSeconds: Double
    let nodeIDs: [Int64]
    let edgeIDs: [Int64]
    let geometry: [CLLocationCoordinate2D]
}
