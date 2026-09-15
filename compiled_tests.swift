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
//
//  CircularAngleHelper.swift
//  Relayn
//
//  Created by Senior iOS Developer on 14/08/26.
//

import Foundation

/// Pure mathematical helper for circular angle calculations and shortest path interpolation
public enum CircularAngleHelper {
    
    /// Calculates the shortest signed angular difference from oldAngle to newAngle in degrees [-180.0, +180.0].
    /// Examples:
    /// - 359° -> 1° = +2.0°
    /// - 1° -> 359° = -2.0°
    /// - 350° -> 10° = +20.0°
    /// - 10° -> 350° = -20.0°
    /// - 179° -> 181° = +2.0°
    public static func shortestAngularDifference(from oldAngle: Double, to newAngle: Double) -> Double {
        let delta = (newAngle - oldAngle + 540.0).truncatingRemainder(dividingBy: 360.0) - 180.0
        return delta
    }
}
import Foundation
import SQLite3
import CoreLocation

struct RoutingMetadata {
    var schemaVersion: String
    var graphVersion: String
    var regionId: String
    var regionName: String
    var profile: String
    var nodeCount: Int
    var edgeCount: Int
}

struct RoutingRegion {
    var minLat: Double
    var maxLat: Double
    var minLon: Double
    var maxLon: Double
    
    func contains(_ coord: CLLocationCoordinate2D) -> Bool {
        return coord.latitude >= minLat && coord.latitude <= maxLat &&
               coord.longitude >= minLon && coord.longitude <= maxLon
    }
}

struct RoutingRestriction {
    var toEdgeId: Int64
    var type: Int // 0: NO_TURN, 1: ONLY_TURN
}

final class RoutingDatabase: Sendable {
    private let fileURL: URL
    // SQLite3 pointers are not Sendable, so we use a serial queue to protect access.
    // For a pure offline router, this is safe and prevents concurrency issues.
    private let dbQueue = DispatchQueue(label: "com.relyvo.RoutingDatabase", qos: .userInitiated)
    
    init(fileURL: URL) {
        self.fileURL = fileURL
    }
    
    private func withDB<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        return try dbQueue.sync {
            var db: OpaquePointer?
            if sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                throw RoutingError.databaseError("Failed to open routing database")
            }
            defer { sqlite3_close(db) }
            return try block(db!)
        }
    }
    
    func metadata() throws -> RoutingMetadata {
        return try withDB { db in
            var schemaVersion = "", graphVersion = "", regionId = "", regionName = "", profile = ""
            var nodeCount = 0, edgeCount = 0
            
            let query = "SELECT key, value FROM metadata;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let k = sqlite3_column_text(statement, 0), let v = sqlite3_column_text(statement, 1) {
                        let key = String(cString: k)
                        let value = String(cString: v)
                        switch key {
                        case "schema_version": schemaVersion = value
                        case "graph_version": graphVersion = value
                        case "region_id": regionId = value
                        case "region_name": regionName = value
                        case "profile": profile = value
                        case "node_count": nodeCount = Int(value) ?? 0
                        case "edge_count": edgeCount = Int(value) ?? 0
                        default: break
                        }
                    }
                }
            } else {
                throw RoutingError.databaseError("Failed to prepare metadata query")
            }
            sqlite3_finalize(statement)
            return RoutingMetadata(schemaVersion: schemaVersion, graphVersion: graphVersion, regionId: regionId, regionName: regionName, profile: profile, nodeCount: nodeCount, edgeCount: edgeCount)
        }
    }
    
    func region() throws -> RoutingRegion {
        return try withDB { db in
            let query = "SELECT min_lat, max_lat, min_lon, max_lon FROM region WHERE id = 1 LIMIT 1;"
            var statement: OpaquePointer?
            var region: RoutingRegion?
            
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    region = RoutingRegion(
                        minLat: sqlite3_column_double(statement, 0),
                        maxLat: sqlite3_column_double(statement, 1),
                        minLon: sqlite3_column_double(statement, 2),
                        maxLon: sqlite3_column_double(statement, 3)
                    )
                }
            }
            sqlite3_finalize(statement)
            guard let r = region else { throw RoutingError.invalidGraph }
            return r
        }
    }
    
    func nearestNode(to coordinate: CLLocationCoordinate2D, searchRadiusDegrees: Double = 0.05) throws -> RoadNode {
        return try withDB { db in
            let minLat = coordinate.latitude - searchRadiusDegrees
            let maxLat = coordinate.latitude + searchRadiusDegrees
            let minLon = coordinate.longitude - searchRadiusDegrees
            let maxLon = coordinate.longitude + searchRadiusDegrees
            
            let query = """
            SELECT r.id, n.lat, n.lon 
            FROM rtree_nodes r 
            JOIN nodes n ON r.id = n.id 
            WHERE r.minLat >= ? AND r.maxLat <= ? 
            AND r.minLon >= ? AND r.maxLon <= ?;
            """
            var statement: OpaquePointer?
            var bestNode: RoadNode?
            var minDistance = Double.greatestFiniteMagnitude
            
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_double(statement, 1, minLat)
                sqlite3_bind_double(statement, 2, maxLat)
                sqlite3_bind_double(statement, 3, minLon)
                sqlite3_bind_double(statement, 4, maxLon)
                
                let targetLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                
                while sqlite3_step(statement) == SQLITE_ROW {
                    let id = sqlite3_column_int64(statement, 0)
                    let lat = sqlite3_column_double(statement, 1)
                    let lon = sqlite3_column_double(statement, 2)
                    let candidateLoc = CLLocation(latitude: lat, longitude: lon)
                    let distance = candidateLoc.distance(from: targetLoc)
                    
                    if distance < minDistance {
                        minDistance = distance
                        bestNode = RoadNode(id: id, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }
                }
            } else {
                throw RoutingError.databaseError("Failed to query R-Tree")
            }
            sqlite3_finalize(statement)
            
            guard let node = bestNode else { throw RoutingError.originNodeNotFound }
            return node
        }
    }
    
    func node(id: Int64) throws -> RoadNode {
        return try withDB { db in
            let query = "SELECT lat, lon FROM nodes WHERE id = ? LIMIT 1;"
            var statement: OpaquePointer?
            var node: RoadNode?
            
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int64(statement, 1, id)
                if sqlite3_step(statement) == SQLITE_ROW {
                    let lat = sqlite3_column_double(statement, 0)
                    let lon = sqlite3_column_double(statement, 1)
                    node = RoadNode(id: id, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
            }
            sqlite3_finalize(statement)
            guard let n = node else { throw RoutingError.invalidGraph }
            return n
        }
    }
    
    func outgoingEdges(from nodeId: Int64) throws -> [RoadEdge] {
        return try withDB { db in
            let query = "SELECT edge_id, osm_way_id, u, v, length_m, speed_kph, road_class, name, oneway FROM edges WHERE u = ?;"
            var statement: OpaquePointer?
            var edges = [RoadEdge]()
            
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int64(statement, 1, nodeId)
                while sqlite3_step(statement) == SQLITE_ROW {
                    let nameRaw = sqlite3_column_text(statement, 7)
                    let name = nameRaw != nil ? String(cString: nameRaw!) : nil
                    let roadClassRaw = sqlite3_column_text(statement, 6)
                    let roadClass = roadClassRaw != nil ? String(cString: roadClassRaw!) : "unknown"
                    
                    edges.append(RoadEdge(
                        edgeID: sqlite3_column_int64(statement, 0),
                        osmWayID: sqlite3_column_int64(statement, 1),
                        sourceNodeID: sqlite3_column_int64(statement, 2),
                        destinationNodeID: sqlite3_column_int64(statement, 3),
                        lengthMeters: sqlite3_column_double(statement, 4),
                        speedKPH: Double(sqlite3_column_int(statement, 5)),
                        roadClass: roadClass,
                        name: name,
                        isOneway: sqlite3_column_int(statement, 8) == 1
                    ))
                }
            } else {
                throw RoutingError.databaseError("Failed to fetch outgoing edges")
            }
            sqlite3_finalize(statement)
            return edges
        }
    }
    
    func edge(id: Int64) throws -> RoadEdge {
        return try withDB { db in
            let query = "SELECT osm_way_id, u, v, length_m, speed_kph, road_class, name, oneway FROM edges WHERE edge_id = ? LIMIT 1;"
            var statement: OpaquePointer?
            var edge: RoadEdge?
            
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int64(statement, 1, id)
                if sqlite3_step(statement) == SQLITE_ROW {
                    let nameRaw = sqlite3_column_text(statement, 6)
                    let name = nameRaw != nil ? String(cString: nameRaw!) : nil
                    let roadClassRaw = sqlite3_column_text(statement, 5)
                    let roadClass = roadClassRaw != nil ? String(cString: roadClassRaw!) : "unknown"
                    
                    edge = RoadEdge(
                        edgeID: id,
                        osmWayID: sqlite3_column_int64(statement, 0),
                        sourceNodeID: sqlite3_column_int64(statement, 1),
                        destinationNodeID: sqlite3_column_int64(statement, 2),
                        lengthMeters: sqlite3_column_double(statement, 3),
                        speedKPH: Double(sqlite3_column_int(statement, 4)),
                        roadClass: roadClass,
                        name: name,
                        isOneway: sqlite3_column_int(statement, 7) == 1
                    )
                }
            }
            sqlite3_finalize(statement)
            guard let e = edge else { throw RoutingError.invalidGraph }
            return e
        }
    }
    
    func edgeGeometry(for edgeId: Int64) throws -> [CLLocationCoordinate2D] {
        return try withDB { db in
            let query = "SELECT geometry FROM edge_geometry WHERE edge_id = ? LIMIT 1;"
            var statement: OpaquePointer?
            var coords = [CLLocationCoordinate2D]()
            
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int64(statement, 1, edgeId)
                if sqlite3_step(statement) == SQLITE_ROW {
                    if let blobPointer = sqlite3_column_blob(statement, 0) {
                        let blobSize = sqlite3_column_bytes(statement, 0)
                        let data = Data(bytes: blobPointer, count: Int(blobSize))
                        if data.count >= 7 {
                            let magic = data.subdata(in: 0..<2)
                            let version = data[2]
                            if magic == "EG".data(using: .ascii) && version == 1 {
                                let countBytes = data.subdata(in: 3..<7)
                                let count = countBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
                                var offset = 7
                                for _ in 0..<count {
                                    if offset + 8 > data.count { break }
                                    let latBytes = data.subdata(in: offset..<offset+4)
                                    let lonBytes = data.subdata(in: offset+4..<offset+8)
                                    let latInt = latBytes.withUnsafeBytes { $0.load(as: Int32.self) }
                                    let lonInt = lonBytes.withUnsafeBytes { $0.load(as: Int32.self) }
                                    coords.append(CLLocationCoordinate2D(latitude: Double(latInt) / 1_000_000.0, longitude: Double(lonInt) / 1_000_000.0))
                                    offset += 8
                                }
                            }
                        }
                    }
                }
            } else {
                throw RoutingError.databaseError("Failed to fetch geometry")
            }
            sqlite3_finalize(statement)
            return coords
        }
    }
    
    func restrictedTransitions(from edgeId: Int64) throws -> [RoutingRestriction] {
        return try withDB { db in
            let query = "SELECT to_edge, restriction_type FROM restricted_turns WHERE from_edge = ?;"
            var statement: OpaquePointer?
            var restrictions = [RoutingRestriction]()
            
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int64(statement, 1, edgeId)
                while sqlite3_step(statement) == SQLITE_ROW {
                    restrictions.append(RoutingRestriction(
                        toEdgeId: sqlite3_column_int64(statement, 0),
                        type: Int(sqlite3_column_int(statement, 1))
                    ))
                }
            } else {
                throw RoutingError.databaseError("Failed to fetch restrictions")
            }
            sqlite3_finalize(statement)
            return restrictions
        }
    }
}
import Foundation
import CoreLocation

/// Represents a state in the A* search
private struct SearchState: Hashable {
    let nodeID: Int64
    let previousEdgeID: Int64?
    
    init(nodeID: Int64, previousEdgeID: Int64? = nil) {
        self.nodeID = nodeID
        self.previousEdgeID = previousEdgeID
    }
}

/// A node in the priority queue
private struct PQNode: Comparable {
    let state: SearchState
    let fScore: Double
    let gScore: Double
    
    static func < (lhs: PQNode, rhs: PQNode) -> Bool {
        if lhs.fScore == rhs.fScore {
            // Tie-breaker: favor higher gScore (closer to destination)
            return lhs.gScore > rhs.gScore
        }
        return lhs.fScore < rhs.fScore
    }
    
    static func == (lhs: PQNode, rhs: PQNode) -> Bool {
        return lhs.state == rhs.state
    }
}

/// Binary Min-Heap Priority Queue
private struct PriorityQueue<T: Comparable> {
    private var heap = [T]()
    
    var isEmpty: Bool { heap.isEmpty }
    var count: Int { heap.count }
    
    mutating func push(_ element: T) {
        heap.append(element)
        siftUp(from: heap.count - 1)
    }
    
    mutating func pop() -> T? {
        if heap.isEmpty { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let root = heap[0]
        heap[0] = heap.removeLast()
        siftDown(from: 0)
        return root
    }
    
    private mutating func siftUp(from index: Int) {
        var child = index
        var parent = (child - 1) / 2
        while child > 0 && heap[child] < heap[parent] {
            heap.swapAt(child, parent)
            child = parent
            parent = (child - 1) / 2
        }
    }
    
    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let leftChild = 2 * parent + 1
            let rightChild = 2 * parent + 2
            var candidate = parent
            if leftChild < heap.count && heap[leftChild] < heap[candidate] {
                candidate = leftChild
            }
            if rightChild < heap.count && heap[rightChild] < heap[candidate] {
                candidate = rightChild
            }
            if candidate == parent { return }
            heap.swapAt(parent, candidate)
            parent = candidate
        }
    }
}

/// Core offline routing engine.
final class OfflineRoutingService: Sendable {
    private let database: RoutingDatabase
    
    init(database: RoutingDatabase) {
        self.database = database
    }
    
    /// Calculate route from origin to destination entirely offline.
    func calculateRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> Route {
        
        // Phase 10: Region Validation
        let region = try database.region()
        guard region.contains(origin) && region.contains(destination) else {
            throw RoutingError.regionUnavailable
        }
        
        // Phase 9: Destination Handling (Node Snapping)
        let startNode = try database.nearestNode(to: origin)
        let endNode = try database.nearestNode(to: destination)
        
        if startNode.id == endNode.id {
            throw RoutingError.noRouteFound
        }
        
        // A* State Management
        var openQueue = PriorityQueue<PQNode>()
        var gScores = [SearchState: Double]()
        var cameFromNode = [SearchState: SearchState]()
        var cameFromEdge = [SearchState: Int64]()
        
        // Initial State
        let startState = SearchState(nodeID: startNode.id, previousEdgeID: nil)
        gScores[startState] = 0.0
        openQueue.push(PQNode(state: startState, fScore: heuristic(from: startNode, to: endNode), gScore: 0.0))
        
        var reachedEndState: SearchState?
        
        // A* Loop
        while let current = openQueue.pop() {
            // Check cancellation periodically
            try Task.checkCancellation()
            
            let currentState = current.state
            
            // Reached destination?
            if currentState.nodeID == endNode.id {
                reachedEndState = currentState
                break
            }
            
            // Skip if we already found a strictly better path to this exact state
            if let bestG = gScores[currentState], bestG < current.gScore {
                continue
            }
            
            // Expand neighbors
            let outgoingEdges = try database.outgoingEdges(from: currentState.nodeID)
            
            // Load restrictions if we arrived via an edge
            var restrictions = [RoutingRestriction]()
            if let prevEdgeID = currentState.previousEdgeID {
                restrictions = try database.restrictedTransitions(from: prevEdgeID)
            }
            
            for edge in outgoingEdges {
                let candidateEdgeID = edge.edgeID
                
                // Phase 8: Turn Restrictions
                var isRestricted = false
                var hasOnlyTurn = false
                var allowedOnlyTurnEdge: Int64? = nil
                
                for r in restrictions {
                    if r.type == 0 { // NO_TURN
                        if r.toEdgeId == candidateEdgeID {
                            isRestricted = true
                            break
                        }
                    } else if r.type == 1 { // ONLY_TURN
                        hasOnlyTurn = true
                        if r.toEdgeId == candidateEdgeID {
                            allowedOnlyTurnEdge = candidateEdgeID
                        }
                    }
                }
                
                if isRestricted { continue }
                if hasOnlyTurn && allowedOnlyTurnEdge != candidateEdgeID {
                    continue
                }
                
                // tentative_gScore = gScore + length
                let tentativeG = current.gScore + edge.lengthMeters
                let nextState = SearchState(nodeID: edge.destinationNodeID, previousEdgeID: candidateEdgeID)
                
                let existingG = gScores[nextState] ?? Double.greatestFiniteMagnitude
                
                if tentativeG < existingG {
                    cameFromNode[nextState] = currentState
                    cameFromEdge[nextState] = candidateEdgeID
                    gScores[nextState] = tentativeG
                    
                    let nextNode = try database.node(id: edge.destinationNodeID)
                    let h = heuristic(from: nextNode, to: endNode)
                    let f = tentativeG + h
                    
                    openQueue.push(PQNode(state: nextState, fScore: f, gScore: tentativeG))
                }
            }
        }
        
        // Phase 11: Route Reconstruction
        guard let finalState = reachedEndState else {
            throw RoutingError.noRouteFound
        }
        
        var pathNodes = [Int64]()
        var pathEdges = [Int64]()
        
        var cur: SearchState? = finalState
        while let s = cur {
            pathNodes.append(s.nodeID)
            if let edge = cameFromEdge[s] {
                pathEdges.append(edge)
            }
            cur = cameFromNode[s]
        }
        
        // Reconstruct from Origin -> Destination
        pathNodes.reverse()
        pathEdges.reverse()
        
        // Phase 12 & 13 & 14: Geometry, Distance, ETA
        var totalDistance: Double = 0
        var totalSeconds: Double = 0
        var geometry = [CLLocationCoordinate2D]()
        
        for edgeID in pathEdges {
            let edge = try database.edge(id: edgeID)
            totalDistance += edge.lengthMeters
            
            let speed = edge.speedKPH > 0 ? edge.speedKPH : 50.0 // fallback 50kph
            let speedMPS = speed * (1000.0 / 3600.0)
            totalSeconds += (edge.lengthMeters / speedMPS)
            
            let edgeCoords = try database.edgeGeometry(for: edgeID)
            
            if geometry.isEmpty {
                geometry.append(contentsOf: edgeCoords)
            } else {
                // To avoid duplicate shared points between edges
                if let first = edgeCoords.first, let lastGeom = geometry.last,
                   abs(first.latitude - lastGeom.latitude) < 0.00001 && abs(first.longitude - lastGeom.longitude) < 0.00001 {
                    geometry.append(contentsOf: edgeCoords.dropFirst())
                } else {
                    geometry.append(contentsOf: edgeCoords)
                }
            }
        }
        
        // Final fallback if missing initial coordinates
        if geometry.isEmpty {
            geometry = [startNode.coordinate, endNode.coordinate]
        }
        
        return Route(
            origin: origin,
            destination: destination,
            totalDistanceMeters: totalDistance,
            estimatedTravelTimeSeconds: totalSeconds,
            nodeIDs: pathNodes,
            edgeIDs: pathEdges,
            geometry: geometry
        )
    }
    
    private func heuristic(from start: RoadNode, to end: RoadNode) -> Double {
        let startLoc = CLLocation(latitude: start.coordinate.latitude, longitude: start.coordinate.longitude)
        let endLoc = CLLocation(latitude: end.coordinate.latitude, longitude: end.coordinate.longitude)
        // Return geographical great-circle distance as the admissible heuristic
        return startLoc.distance(from: endLoc)
    }
}
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
            let edge = try routingDatabase.edge(id: route.edgeIDs[segmentIndex])
            currentStreetName = edge.name
        }
        
        // Look ahead for meaningful change
        var lookaheadIdx = segmentIndex + 1
        var accumulatedDist = 0.0
        
        while lookaheadIdx < route.geometry.count - 1 {
            let nextBearing = calculateBearing(from: route.geometry[lookaheadIdx], to: route.geometry[lookaheadIdx+1])
            let diff = shortestAngularDifference(from: currentBearing, to: nextBearing)
            
            var nextStreetName: String? = nil
            if lookaheadIdx < route.edgeIDs.count {
                let edge = try routingDatabase.edge(id: route.edgeIDs[lookaheadIdx])
                nextStreetName = edge.name
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
import Foundation
import CoreLocation

@MainActor
public final class RouteProgressTests {
    
    public static let shared = RouteProgressTests()
    
    private var passed = 0
    private var failed = 0
    
    private func assert(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("✅ PASS: \(message)")
        } else {
            failed += 1
            print("❌ FAIL: \(message)")
        }
    }
    
    public func runAllTests() async -> (passed: Int, failed: Int) {
        passed = 0
        failed = 0
        print("=== STARTING ROUTE PROGRESS VERIFICATION ===")
        
        await testProjectionMidpoint()
        await testProjectionEndpoint()
        await testProgressCalculation()
        await testBearingWraparound()
        await testManeuverClassification()
        await testOffRouteHysteresis()
        await testRerouteCooldown()
        await testArrivalDetection()
        await testMonacoSmokeTest()
        
        print("=== ROUTE PROGRESS VERIFICATION COMPLETE ===")
        print("Passed: \(passed), Failed: \(failed)")
        return (passed, failed)
    }
    
    // MARK: - Mocks
    
    private func createMockService() -> RouteProgressService {
        // Need a dummy DB. In memory is fine if OfflineRoutingService doesn't crash on it.
        // We'll use a dummy memory db for pure logic tests.
        let db = RoutingDatabase(fileURL: URL(fileURLWithPath: ":memory:"))
        let routing = OfflineRoutingService(database: db)
        return RouteProgressService(database: db, routingService: routing)
    }
    
    private func createStraightMockRoute() -> Route {
        return Route(
            origin: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            destination: CLLocationCoordinate2D(latitude: 0, longitude: 0.01),
            totalDistanceMeters: 1113.2,
            estimatedTravelTimeSeconds: 100,
            nodeIDs: [1, 2],
            edgeIDs: [100],
            geometry: [
                CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
                CLLocationCoordinate2D(latitude: 0.0, longitude: 0.01)
            ]
        )
    }
    
    private func createCurvedMockRoute() -> Route {
        return Route(
            origin: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            destination: CLLocationCoordinate2D(latitude: 0.01, longitude: 0.01),
            totalDistanceMeters: 2226.4,
            estimatedTravelTimeSeconds: 200,
            nodeIDs: [1, 2, 3, 4],
            edgeIDs: [100, 101, 102],
            geometry: [
                CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
                CLLocationCoordinate2D(latitude: 0.005, longitude: 0.0),   // North
                CLLocationCoordinate2D(latitude: 0.005, longitude: 0.005), // East (Right turn)
                CLLocationCoordinate2D(latitude: 0.01, longitude: 0.005)   // North (Left turn)
            ]
        )
    }
    
    // MARK: - Tests
    
    private func testProjectionMidpoint() async {
        let service = createMockService()
        await service.setRoute(createStraightMockRoute())
        
        // Exact midpoint of segment 0 (0.0 to 0.01 lon)
        let loc = CLLocation(latitude: 0.0, longitude: 0.005)
        let prog = try? await service.updateProgress(location: loc, heading: 90)
        
        assert(prog != nil, "MidpointProjection: Progress generated")
        if let p = prog {
            assert(p.currentSegmentIndex == 0, "MidpointProjection: Segment index correct")
            assert(abs(p.progressFraction - 0.5) < 0.05, "MidpointProjection: Fraction is ~0.5")
            assert(p.distanceToRouteMeters < 1.0, "MidpointProjection: distance to route is 0")
        }
    }
    
    private func testProjectionEndpoint() async {
        let service = createMockService()
        await service.setRoute(createStraightMockRoute())
        
        let loc = CLLocation(latitude: 0.001, longitude: -0.001) // Slightly behind start
        let prog = try? await service.updateProgress(location: loc, heading: 90)
        if let p = prog {
            assert(p.currentSegmentIndex == 0, "EndpointSnapping: Snaps to first segment")
            assert(p.currentSegmentProgress == 0.0, "EndpointSnapping: Fraction clamped to 0")
        }
    }
    
    private func testProgressCalculation() async {
        let service = createMockService()
        let route = createCurvedMockRoute()
        await service.setRoute(route)
        
        // Loc near the second vertex
        let loc = CLLocation(latitude: 0.005, longitude: 0.001)
        let prog = try? await service.updateProgress(location: loc, heading: nil)
        
        if let p = prog {
            assert(p.distanceAlongRouteMeters > 0, "ProgressCalc: Dist along > 0")
            assert(p.remainingDistanceMeters < route.totalDistanceMeters, "ProgressCalc: Remaining < total")
            assert(p.currentSegmentIndex == 1, "ProgressCalc: Selected correct second segment")
        }
    }
    
    private func testBearingWraparound() async {
        let diff = CircularAngleHelper.shortestAngularDifference(from: 359, to: 1)
        assert(abs(diff - 2.0) < 0.001, "BearingWraparound: 359 -> 1 is +2")
        
        let diff2 = CircularAngleHelper.shortestAngularDifference(from: 1, to: 359)
        assert(abs(diff2 - (-2.0)) < 0.001, "BearingWraparound: 1 -> 359 is -2")
    }
    
    private func testManeuverClassification() async {
        let service = createMockService()
        await service.setRoute(createCurvedMockRoute())
        
        // Start of route (heading North)
        let loc = CLLocation(latitude: 0.001, longitude: 0.0)
        let prog = try? await service.updateProgress(location: loc, heading: nil)
        
        if let p = prog, let m = p.nextManeuver {
            // Next turn is at vertex 2 (Right turn from North to East)
            assert(m.type == .right || m.type == .sharpRight, "ManeuverClass: Detected right turn (\(m.type.rawValue))")
            assert(m.routeSegmentIndex == 1, "ManeuverClass: Attached to correct segment")
        } else {
            assert(false, "ManeuverClass: Failed to detect maneuver")
        }
    }
    
    private func testOffRouteHysteresis() async {
        let service = createMockService()
        await service.setRoute(createStraightMockRoute())
        
        // Move off route by 35 meters (enter threshold is 30)
        // At equator, 1 deg lon = ~111km. 35m = ~0.00031 deg
        var loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.00035, longitude: 0.005),
                             altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        
        var prog = try? await service.updateProgress(location: loc, heading: nil)
        assert(prog?.isOffRoute == true, "Hysteresis: Triggered off-route")
        
        // Move back slightly to 20 meters (below enter, but above exit threshold 15)
        loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.00020, longitude: 0.005),
                         altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        prog = try? await service.updateProgress(location: loc, heading: nil)
        assert(prog?.isOffRoute == true, "Hysteresis: Maintained off-route (hysteresis active)")
        
        // Move back fully to 5 meters (below exit threshold 15)
        loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.00004, longitude: 0.005),
                         altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        prog = try? await service.updateProgress(location: loc, heading: nil)
        assert(prog?.isOffRoute == false, "Hysteresis: Exited off-route successfully")
    }
    
    private func testRerouteCooldown() async {
        let service = createMockService()
        await service.setRoute(createStraightMockRoute())
        
        // Force off route
        let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.00050, longitude: 0.005),
                             altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        
        let _ = try? await service.updateProgress(location: loc, heading: nil)
        // It should attempt a reroute and fail (db is empty), placing stateMachine in .offRoute
        let state = await service.stateMachine
        assert(state == .offRoute, "RerouteCooldown: Engine attempted reroute and reverted to offRoute on failure")
        
        // Update again immediately
        let _ = try? await service.updateProgress(location: loc, heading: nil)
        let state2 = await service.stateMachine
        assert(state2 == .offRoute, "RerouteCooldown: Kept state without spamming reroute task")
    }
    
    private func testArrivalDetection() async {
        let service = createMockService()
        await service.setRoute(createStraightMockRoute())
        
        // Destination is 0.0, 0.01
        let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0099),
                             altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        let prog = try? await service.updateProgress(location: loc, heading: nil)
        
        assert(prog?.isArrived == true, "ArrivalDetection: Arrived near destination")
        assert(prog?.remainingDistanceMeters == 0, "ArrivalDetection: Remaining distance clamped to 0")
    }
    
    private func testMonacoSmokeTest() async {
        let monacoURL = URL(fileURLWithPath: "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite")
        guard FileManager.default.fileExists(atPath: monacoURL.path) else {
            print("⚠️ SKIP: Monaco test DB not found locally.")
            return
        }
        
        let db = RoutingDatabase(fileURL: monacoURL)
        let routing = OfflineRoutingService(database: db)
        let service = RouteProgressService(database: db, routingService: routing)
        
        // Valid nodes in Monaco
        let start = CLLocationCoordinate2D(latitude: 43.7384, longitude: 7.4246)
        let end = CLLocationCoordinate2D(latitude: 43.7400, longitude: 7.4260)
        
        do {
            let route = try await routing.calculateRoute(from: start, to: end)
            await service.setRoute(route)
            
            // Advance loc
            let loc = CLLocation(latitude: 43.7385, longitude: 7.4247)
            let prog = try await service.updateProgress(location: loc, heading: nil)
            
            assert(prog != nil, "MonacoProgress: Successfully updated progress on real route")
            assert(prog?.isOffRoute == false, "MonacoProgress: Started on route")
            if let m = prog?.nextManeuver {
                assert(m.type != .start, "MonacoProgress: Extracted a valid upcoming maneuver")
            }
        } catch {
            assert(false, "MonacoProgress: Failed \(error)")
        }
    }
}

Task { let (_, failed) = await RouteProgressTests.shared.runAllTests(); if failed > 0 { exit(1) } else { exit(0) } }; RunLoop.main.run()
