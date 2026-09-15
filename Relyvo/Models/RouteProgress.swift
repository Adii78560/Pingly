import Foundation
import CoreLocation

/// Type of navigation maneuver to perform
enum ManeuverType: String, Sendable, Equatable {
    case start = "START"
    case `continue` = "CONTINUE"
    case slightRight = "SLIGHT_RIGHT"
    case slightLeft = "SLIGHT_LEFT"
    case right = "RIGHT"
    case left = "LEFT"
    case sharpRight = "SHARP_RIGHT"
    case sharpLeft = "SHARP_LEFT"
    case uTurn = "U_TURN"
    case arrive = "ARRIVE"
}

/// A maneuver generated dynamically during route progress
struct RouteManeuver: Sendable, Equatable {
    let type: ManeuverType
    let location: CLLocationCoordinate2D
    let routeSegmentIndex: Int
    let distanceFromCurrentPosition: Double
    let bearingBefore: Double
    let bearingAfter: Double
    let turnAngle: Double
    let streetName: String?
    let instructionText: String
    
    static func == (lhs: RouteManeuver, rhs: RouteManeuver) -> Bool {
        return lhs.type == rhs.type &&
               lhs.routeSegmentIndex == rhs.routeSegmentIndex &&
               lhs.streetName == rhs.streetName &&
               abs(lhs.distanceFromCurrentPosition - rhs.distanceFromCurrentPosition) < 0.1
    }
}

/// Navigation state snapshot along a route
struct RouteProgress: Sendable, Equatable {
    let route: Route
    let currentPosition: CLLocationCoordinate2D
    let currentSegmentIndex: Int
    let distanceAlongRouteMeters: Double
    let remainingDistanceMeters: Double
    let progressFraction: Double
    let currentSegmentProgress: Double
    let distanceToRouteMeters: Double
    let currentHeading: Double?
    let routeBearing: Double
    let nextManeuver: RouteManeuver?
    let isOffRoute: Bool
    let isArrived: Bool
    let estimatedRemainingTimeSeconds: Double
    
    static func == (lhs: RouteProgress, rhs: RouteProgress) -> Bool {
        // Equatable on Route isn't explicitly defined, but we can compare distance and segments
        return lhs.currentSegmentIndex == rhs.currentSegmentIndex &&
               abs(lhs.distanceAlongRouteMeters - rhs.distanceAlongRouteMeters) < 0.1 &&
               abs(lhs.distanceToRouteMeters - rhs.distanceToRouteMeters) < 0.1 &&
               lhs.isOffRoute == rhs.isOffRoute &&
               lhs.isArrived == rhs.isArrived &&
               lhs.nextManeuver == rhs.nextManeuver
    }
}

/// Navigation Progress State Machine
enum RouteProgressState: String, Sendable, Equatable {
    case onRoute = "ON_ROUTE"
    case offRouteCandidate = "OFF_ROUTE_CANDIDATE"
    case offRoute = "OFF_ROUTE"
    case rerouting = "REROUTING"
    case newRoute = "NEW_ROUTE" // Transient state immediately after reroute succeeds
}
