import Foundation
import CoreLocation

actor RouteProgressService {
    
    // Dependencies
    private let routingDatabase: RoutingDatabase
    private let routingService: OfflineRoutingService
    
    // Current State
    private(set) var activeRoute: Route?
    private(set) var currentProgress: RouteProgress?
    private(set) var stateMachine: RouteProgressState = .offRoute
    
    // Geometry caches
    private var cumulativeDistances: [Double] = []
    
    // Configurable Thresholds
    private let offRouteEnterBaseThreshold: Double = 30.0
    private let offRouteExitBaseThreshold: Double = 15.0
    private let maxAccuracyAllowance: Double = 40.0
    private let arrivalRadius: Double = 15.0
    private let smallBendThreshold: Double = 20.0
    private let turnThreshold: Double = 45.0
    private let sharpTurnThreshold: Double = 120.0
    
    // Reroute Cooldown
    private var lastRerouteTime: Date = Date.distantPast
    private let rerouteCooldown: TimeInterval = 10.0
    
    // Progress Tracking
    private var maxDistanceAchieved: Double = 0.0
    
    init(database: RoutingDatabase, routingService: OfflineRoutingService) {
        self.routingDatabase = database
        self.routingService = routingService
    }
    
    /// Phase 18: Route replacement resets progress state
    func setRoute(_ route: Route) {
        self.activeRoute = route
        self.currentProgress = nil
        self.stateMachine = .onRoute
        self.maxDistanceAchieved = 0.0
        
        // Phase 4: Precompute cumulative distances
        var dists = [Double]()
        var total: Double = 0.0
        
        let geom = route.geometry
        if geom.count > 0 {
            dists.append(0.0)
            for i in 1..<geom.count {
                let d = distanceBetween(geom[i-1], geom[i])
                total += d
                dists.append(total)
            }
        }
        self.cumulativeDistances = dists
    }
    
    /// Entry point for GPS updates (Phase 7)
    func updateProgress(location: CLLocation, heading: Double?) async throws -> RouteProgress? {
        guard let route = activeRoute, route.geometry.count > 1 else { return nil }
        
        // Ensure we don't do work if rerouting is already active
        if stateMachine == .rerouting {
            return currentProgress
        }
        
        // 1. Projection (Phase 3)
        let projection = projectCoordinate(location.coordinate, onto: route.geometry)
        
        // 2. Off Route Hysteresis (Phases 5 & 6)
        let accuracy = location.horizontalAccuracy >= 0 ? min(location.horizontalAccuracy, maxAccuracyAllowance) : 10.0
        let enterThreshold = offRouteEnterBaseThreshold + accuracy
        let exitThreshold = offRouteExitBaseThreshold + accuracy
        
        if stateMachine == .onRoute || stateMachine == .newRoute {
            if projection.distanceToRoute > enterThreshold {
                stateMachine = .offRouteCandidate
            }
        } else if stateMachine == .offRouteCandidate {
            if projection.distanceToRoute > enterThreshold {
                stateMachine = .offRoute
            } else if projection.distanceToRoute < exitThreshold {
                stateMachine = .onRoute
            }
        } else if stateMachine == .offRoute {
            if projection.distanceToRoute < exitThreshold {
                stateMachine = .onRoute
            }
        }
        
        // 3. Reroute Trigger (Phases 14 & 15)
        if stateMachine == .offRoute {
            if Date().timeIntervalSince(lastRerouteTime) > rerouteCooldown {
                triggerReroute(from: location.coordinate)
                return currentProgress
            }
        }
        
        // 4. Progress Monotonicity (Phase 17)
        let distAlong = cumulativeDistances[projection.segmentIndex] + (projection.fraction * distanceBetween(route.geometry[projection.segmentIndex], route.geometry[projection.segmentIndex+1]))
        
        // Don't regress progress unless the user actually went backwards significantly (e.g., missed turn backtracking)
        // If they drop back < 20m, just hold max achieved to prevent wobble.
        var effectiveDistAlong = distAlong
        if effectiveDistAlong < maxDistanceAchieved {
            if (maxDistanceAchieved - effectiveDistAlong) < 20.0 {
                effectiveDistAlong = maxDistanceAchieved // Ignore small wobble backwards
            } else {
                // Legitimate backtrack
                maxDistanceAchieved = effectiveDistAlong
            }
        } else {
            maxDistanceAchieved = effectiveDistAlong
        }
        
        // 5. Remaining Distance
        var remainingDist = route.totalDistanceMeters - effectiveDistAlong
        if remainingDist < 0 { remainingDist = 0 }
        let fraction = min(1.0, max(0.0, effectiveDistAlong / route.totalDistanceMeters))
        
        // 6. Arrival (Phase 13)
        let arrivalThreshold = arrivalRadius + accuracy
        let isArrived = remainingDist <= arrivalThreshold
        
        if isArrived {
            remainingDist = 0
            effectiveDistAlong = route.totalDistanceMeters
        }
        
        // 7. Route Bearing (Phase 8)
        let routeBearing = calculateBearing(from: route.geometry[projection.segmentIndex], to: route.geometry[projection.segmentIndex+1])
        
        // 8. Maneuvers (Phases 9, 11, 12)
        let maneuver = try await detectNextManeuver(
            route: route,
            segmentIndex: projection.segmentIndex,
            currentDistAlong: effectiveDistAlong,
            cumulative: cumulativeDistances,
            isArrived: isArrived
        )
        
        let progress = RouteProgress(
            route: route,
            currentPosition: projection.projected,
            currentSegmentIndex: projection.segmentIndex,
            distanceAlongRouteMeters: effectiveDistAlong,
            remainingDistanceMeters: remainingDist,
            progressFraction: fraction,
            currentSegmentProgress: projection.fraction,
            distanceToRouteMeters: projection.distanceToRoute,
            currentHeading: heading,
            routeBearing: routeBearing,
            nextManeuver: maneuver,
            isOffRoute: (stateMachine == .offRoute || stateMachine == .offRouteCandidate),
            isArrived: isArrived,
            estimatedRemainingTimeSeconds: remainingDist / (50.0 * 1000.0 / 3600.0) // fallback 50kph
        )
        
        self.currentProgress = progress
        return progress
    }
    
    private var rerouteTask: Task<Void, Never>?
    
    private func triggerReroute(from origin: CLLocationCoordinate2D) {
        guard let dest = activeRoute?.destination else { return }
        self.stateMachine = .rerouting
        self.lastRerouteTime = Date()
        
        rerouteTask?.cancel()
        rerouteTask = Task {
            do {
                let newRoute = try await routingService.calculateRoute(from: origin, to: dest)
                if !Task.isCancelled {
                    self.setRoute(newRoute)
                    self.stateMachine = .newRoute
                }
            } catch {
                if !Task.isCancelled {
                    self.stateMachine = .offRoute // Revert state so we can try again after cooldown
                }
            }
        }
    }
    
    // MARK: - Geometry Projections
    
    private func projectCoordinate(_ p: CLLocationCoordinate2D, onto polyline: [CLLocationCoordinate2D]) -> (projected: CLLocationCoordinate2D, segmentIndex: Int, distanceToRoute: Double, fraction: Double) {
        var bestDist = Double.greatestFiniteMagnitude
        var bestProj = p
        var bestIdx = 0
        var bestFrac = 0.0
        
        for i in 0..<(polyline.count - 1) {
            let a = polyline[i]
            let b = polyline[i+1]
            
            let proj = projectOntoSegment(p: p, a: a, b: b)
            if proj.distance < bestDist {
                bestDist = proj.distance
                bestProj = proj.projected
                bestIdx = i
                bestFrac = proj.fraction
            }
        }
        return (bestProj, bestIdx, bestDist, bestFrac)
    }
    
    private func projectOntoSegment(p: CLLocationCoordinate2D, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> (projected: CLLocationCoordinate2D, distance: Double, fraction: Double) {
        // Local equirectangular projection centered on a
        let earthRadius = 6371000.0
        let latToMeters = earthRadius * .pi / 180.0
        let cosLat = cos(a.latitude * .pi / 180.0)
        let lonToMeters = latToMeters * cosLat
        
        let pX = (p.longitude - a.longitude) * lonToMeters
        let pY = (p.latitude - a.latitude) * latToMeters
        
        let bX = (b.longitude - a.longitude) * lonToMeters
        let bY = (b.latitude - a.latitude) * latToMeters
        
        let abSq = bX * bX + bY * bY
        if abSq == 0 {
            let distSq = pX * pX + pY * pY
            return (a, sqrt(distSq), 0.0)
        }
        
        let t = max(0, min(1, (pX * bX + pY * bY) / abSq))
        
        let projX = t * bX
        let projY = t * bY
        
        let dx = pX - projX
        let dy = pY - projY
        let dist = sqrt(dx * dx + dy * dy)
        
        let projLat = a.latitude + (projY / latToMeters)
        let projLon = a.longitude + (projX / lonToMeters)
        
        return (CLLocationCoordinate2D(latitude: projLat, longitude: projLon), dist, t)
    }
    
    // MARK: - Maneuver Generation
    
    private func detectNextManeuver(route: Route, segmentIndex: Int, currentDistAlong: Double, cumulative: [Double], isArrived: Bool) async throws -> RouteManeuver? {
        if isArrived {
            return RouteManeuver(
                type: .arrive, location: route.destination, routeSegmentIndex: route.geometry.count - 1,
                distanceFromCurrentPosition: 0, bearingBefore: 0, bearingAfter: 0, turnAngle: 0, streetName: nil, instructionText: "Arrived at destination"
            )
        }
        
        var currentBearing = calculateBearing(from: route.geometry[segmentIndex], to: route.geometry[segmentIndex+1])
        var currentStreetName: String? = nil
        if segmentIndex < route.edgeIDs.count {
            if let edge = try? routingDatabase.edge(id: route.edgeIDs[segmentIndex]) {
                currentStreetName = edge.name
            }
        }
        
        // Look ahead for meaningful change
        var lookaheadIdx = segmentIndex + 1
        var accumulatedDist = 0.0
        
        while lookaheadIdx < route.geometry.count - 1 {
            let nextBearing = calculateBearing(from: route.geometry[lookaheadIdx], to: route.geometry[lookaheadIdx+1])
            let diff = shortestAngularDifference(from: currentBearing, to: nextBearing)
            
            var nextStreetName: String? = nil
            if lookaheadIdx < route.edgeIDs.count {
                if let edge = try? routingDatabase.edge(id: route.edgeIDs[lookaheadIdx]) {
                    nextStreetName = edge.name
                }
            }
            
            let isSignificantTurn = abs(diff) > smallBendThreshold
            let isNameChange = currentStreetName != nextStreetName && nextStreetName != nil
            
            if isSignificantTurn || isNameChange {
                let turnType = classifyTurn(angle: diff)
                let distToManeuver = cumulative[lookaheadIdx] - currentDistAlong
                
                return RouteManeuver(
                    type: turnType,
                    location: route.geometry[lookaheadIdx],
                    routeSegmentIndex: lookaheadIdx,
                    distanceFromCurrentPosition: max(0, distToManeuver),
                    bearingBefore: currentBearing,
                    bearingAfter: nextBearing,
                    turnAngle: diff,
                    streetName: nextStreetName,
                    instructionText: generateInstruction(type: turnType, street: nextStreetName)
                )
            }
            
            currentBearing = nextBearing
            lookaheadIdx += 1
        }
        
        return nil
    }
    
    private func classifyTurn(angle: Double) -> ManeuverType {
        let a = abs(angle)
        if a < smallBendThreshold { return .continue }
        else if a < turnThreshold { return angle > 0 ? .slightRight : .slightLeft }
        else if a < sharpTurnThreshold { return angle > 0 ? .right : .left }
        else if a < 170.0 { return angle > 0 ? .sharpRight : .sharpLeft }
        else { return .uTurn }
    }
    
    private func generateInstruction(type: ManeuverType, street: String?) -> String {
        let base: String
        switch type {
        case .continue: base = "Continue"
        case .slightRight: base = "Slight right"
        case .slightLeft: base = "Slight left"
        case .right: base = "Turn right"
        case .left: base = "Turn left"
        case .sharpRight: base = "Sharp right"
        case .sharpLeft: base = "Sharp left"
        case .uTurn: base = "Make a U-turn"
        case .arrive: base = "Arrive"
        case .start: base = "Start"
        }
        
        if let s = street, !s.isEmpty {
            return "\(base) onto \(s)"
        }
        return base
    }
    
    // MARK: - Helpers
    
    private func distanceBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let loc2 = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return loc1.distance(from: loc2)
    }
    
    private func calculateBearing(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
        let lat1 = source.latitude * .pi / 180.0
        let lon1 = source.longitude * .pi / 180.0
        let lat2 = destination.latitude * .pi / 180.0
        let lon2 = destination.longitude * .pi / 180.0
        
        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180.0 / .pi
        return (degrees + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
    
    private func shortestAngularDifference(from oldAngle: Double, to newAngle: Double) -> Double {
        return (newAngle - oldAngle + 540.0).truncatingRemainder(dividingBy: 360.0) - 180.0
    }
}
