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
        case .databaseError(let msg): return "Database error: \\(msg)"
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
import SQLite3
import CoreLocation
import os

final class RoutingTests {
    static let shared = RoutingTests()
    
    private var mockDBURL: URL!
    private var passed = 0
    private var failed = 0
    
    private init() {}
    
    private func assert(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("✅ PASS: \(message)")
        } else {
            failed += 1
            print("❌ FAIL: \(message)")
        }
    }
    
    func runAllTests() async -> (passed: Int, failed: Int) {
        print("=== STARTING ROUTING ENGINE VERIFICATION ===")
        passed = 0
        failed = 0
        
        do {
            try setUp()
            
            await testRoutingDataUnavailable()
            await testRegionUnavailable()
            await testDirectRoute()
            await testMultiHopRoute()
            await testShortestPathChoice()
            await testOneWayEnforcement()
            await testNoRouteFound()
            await testTurnNOTURN()
            await testTurnONLYTURN()
            await testGeometryReconstruction()
            await testDistanceAndETA()
            await testCancellation()
            await testMonacoSmokeTest()
            
            try tearDown()
            
        } catch {
            print("❌ FATAL: Test harness failed to set up: \\(error)")
            failed += 1
        }
        
        print("=== ROUTING ENGINE VERIFICATION COMPLETE ===")
        print("Passed: \(passed), Failed: \(failed)")
        return (passed, failed)
    }
    
    private func setUp() throws {
        let tempDir = FileManager.default.temporaryDirectory
        mockDBURL = tempDir.appendingPathComponent("mock_graph.sqlite")
        try createMockDatabase(at: mockDBURL)
    }
    
    private func tearDown() throws {
        if FileManager.default.fileExists(atPath: mockDBURL.path) {
            try FileManager.default.removeItem(at: mockDBURL)
        }
    }
    
    private func createMockDatabase(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        
        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create mock DB"])
        }
        defer { sqlite3_close(db) }
        
        let schema = """
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE region (id INTEGER PRIMARY KEY, min_lat REAL, max_lat REAL, min_lon REAL, max_lon REAL);
        CREATE TABLE nodes (id INTEGER PRIMARY KEY, lat REAL, lon REAL);
        CREATE VIRTUAL TABLE rtree_nodes USING rtree(id, minLat, maxLat, minLon, maxLon);
        CREATE TABLE edges (edge_id INTEGER PRIMARY KEY, osm_way_id INTEGER, u INTEGER, v INTEGER, length_m REAL, speed_kph INTEGER, road_class TEXT, name TEXT, oneway INTEGER);
        CREATE TABLE edge_geometry (edge_id INTEGER PRIMARY KEY, geometry BLOB);
        CREATE TABLE restricted_turns (from_edge INTEGER, to_edge INTEGER, restriction_type INTEGER);
        """
        
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            throw NSError(domain: "Test", code: 2, userInfo: nil)
        }
        
        let inserts = """
        INSERT INTO metadata (key, value) VALUES ('region_id', 'mock');
        INSERT INTO region (id, min_lat, max_lat, min_lon, max_lon) VALUES (1, -10, 20, -10, 20);
        
        INSERT INTO nodes (id, lat, lon) VALUES (1, 0.0, 0.0);
        INSERT INTO rtree_nodes (id, minLat, maxLat, minLon, maxLon) VALUES (1, 0.0, 0.0, 0.0, 0.0);
        INSERT INTO nodes (id, lat, lon) VALUES (2, 0.0, 1.0);
        INSERT INTO rtree_nodes (id, minLat, maxLat, minLon, maxLon) VALUES (2, 0.0, 0.0, 1.0, 1.0);
        INSERT INTO nodes (id, lat, lon) VALUES (3, 0.0, 2.0);
        INSERT INTO rtree_nodes (id, minLat, maxLat, minLon, maxLon) VALUES (3, 0.0, 0.0, 2.0, 2.0);
        INSERT INTO nodes (id, lat, lon) VALUES (4, 0.0, 3.0);
        INSERT INTO rtree_nodes (id, minLat, maxLat, minLon, maxLon) VALUES (4, 0.0, 0.0, 3.0, 3.0);
        INSERT INTO nodes (id, lat, lon) VALUES (5, 1.0, 1.5);
        INSERT INTO rtree_nodes (id, minLat, maxLat, minLon, maxLon) VALUES (5, 1.0, 1.0, 1.5, 1.5);
        INSERT INTO nodes (id, lat, lon) VALUES (6, 10.0, 10.0);
        INSERT INTO rtree_nodes (id, minLat, maxLat, minLon, maxLon) VALUES (6, 10.0, 10.0, 10.0, 10.0);
        
        INSERT INTO edges (edge_id, osm_way_id, u, v, length_m, speed_kph, oneway) VALUES (10, 100, 1, 2, 1000, 50, 1);
        INSERT INTO edges (edge_id, osm_way_id, u, v, length_m, speed_kph, oneway) VALUES (20, 100, 2, 3, 1000, 50, 1);
        INSERT INTO edges (edge_id, osm_way_id, u, v, length_m, speed_kph, oneway) VALUES (30, 100, 3, 4, 1000, 50, 1);
        
        INSERT INTO edges (edge_id, osm_way_id, u, v, length_m, speed_kph, oneway) VALUES (25, 200, 2, 5, 2000, 50, 1);
        INSERT INTO edges (edge_id, osm_way_id, u, v, length_m, speed_kph, oneway) VALUES (53, 200, 5, 3, 2000, 50, 1);
        
        INSERT INTO edges (edge_id, osm_way_id, u, v, length_m, speed_kph, oneway) VALUES (32, 300, 3, 2, 10, 50, 1);
        
        INSERT INTO restricted_turns (from_edge, to_edge, restriction_type) VALUES (10, 20, 0);
        """
        
        sqlite3_exec(db, inserts, nil, nil, nil)
        
        let stmtStr = "INSERT INTO edge_geometry (edge_id, geometry) VALUES (?, ?);"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, stmtStr, -1, &stmt, nil)
        
        let magic: [UInt8] = [69, 71, 1] // EG, 1
        var count: UInt32 = 2
        let countData = Data(bytes: &count, count: 4)
        var lat1: Int32 = 0, lon1: Int32 = 0
        var lat2: Int32 = 0, lon2: Int32 = 1_000_000
        
        var geomData = Data(magic)
        geomData.append(countData)
        geomData.append(Data(bytes: &lat1, count: 4))
        geomData.append(Data(bytes: &lon1, count: 4))
        geomData.append(Data(bytes: &lat2, count: 4))
        geomData.append(Data(bytes: &lon2, count: 4))
        
        sqlite3_bind_int(stmt, 1, 10)
        geomData.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(geomData.count), nil)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
    
    // MARK: - Test Cases
    
    func testRoutingDataUnavailable() async {
        let badURL = URL(fileURLWithPath: "/does/not/exist.sqlite")
        let db = RoutingDatabase(fileURL: badURL)
        let service = OfflineRoutingService(database: db)
        do {
            _ = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 0), to: CLLocationCoordinate2D(latitude: 0, longitude: 1))
            assert(false, "RoutingDataUnavailable: Should have thrown")
        } catch RoutingError.databaseError {
            assert(true, "RoutingDataUnavailable: Handled")
        } catch {
            assert(false, "RoutingDataUnavailable: Wrong error \\(error)")
        }
    }
    
    func testRegionUnavailable() async {
        let db = RoutingDatabase(fileURL: mockDBURL)
        let service = OfflineRoutingService(database: db)
        do {
            _ = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 100, longitude: 100), to: CLLocationCoordinate2D(latitude: 0, longitude: 1))
            assert(false, "RegionUnavailable: Should fail validation")
        } catch RoutingError.regionUnavailable {
            assert(true, "RegionUnavailable: Handled")
        } catch {
            assert(false, "RegionUnavailable: Wrong error")
        }
    }
    
    func testDirectRoute() async {
        do {
            let db = try buildDirectGraph()
            let service = OfflineRoutingService(database: db)
            let route = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 0), to: CLLocationCoordinate2D(latitude: 0, longitude: 1))
            assert(route.nodeIDs == [1, 2] && route.edgeIDs == [10], "DirectRoute: Found correct path")
        } catch {
            assert(false, "DirectRoute: Failed with error \\(error)")
        }
    }
    
    func testMultiHopRoute() async {
        do {
            let db = try buildDirectGraph()
            let service = OfflineRoutingService(database: db)
            let route = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 0), to: CLLocationCoordinate2D(latitude: 0, longitude: 3))
            assert(route.nodeIDs == [1, 2, 3, 4] && route.edgeIDs == [10, 20, 30], "MultiHopRoute: Found correct path")
        } catch {
            assert(false, "MultiHopRoute: Failed")
        }
    }
    
    func testShortestPathChoice() async {
        do {
            let noRestDB = try buildDirectGraph()
            let service = OfflineRoutingService(database: noRestDB)
            let route = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 1), to: CLLocationCoordinate2D(latitude: 0, longitude: 2))
            assert(route.edgeIDs == [20], "ShortestPathChoice: Chose shorter edge 20 over alternate 25,53")
        } catch {
            assert(false, "ShortestPathChoice: Failed")
        }
    }
    
    func testOneWayEnforcement() async {
        do {
            let db = try buildDirectGraph()
            let service = OfflineRoutingService(database: db)
            _ = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 3), to: CLLocationCoordinate2D(latitude: 0, longitude: 0))
            assert(false, "OneWayEnforcement: Should not find route against one-ways")
        } catch RoutingError.noRouteFound {
            assert(true, "OneWayEnforcement: Handled")
        } catch {
            assert(false, "OneWayEnforcement: Wrong error")
        }
    }
    
    func testNoRouteFound() async {
        do {
            let db = try buildDirectGraph()
            let service = OfflineRoutingService(database: db)
            _ = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 0), to: CLLocationCoordinate2D(latitude: 10, longitude: 10))
            assert(false, "NoRouteFound: Should not find route")
        } catch RoutingError.noRouteFound {
            assert(true, "NoRouteFound: Handled")
        } catch {
            assert(false, "NoRouteFound: Wrong error")
        }
    }
    
    func testTurnNOTURN() async {
        do {
            let db = RoutingDatabase(fileURL: mockDBURL) // Mock has NO_TURN on 10->20
            let service = OfflineRoutingService(database: db)
            let route = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 0), to: CLLocationCoordinate2D(latitude: 0, longitude: 2))
            assert(route.edgeIDs == [10, 25, 53], "TurnNOTURN: Handled NO_TURN properly")
        } catch {
            assert(false, "TurnNOTURN: Failed")
        }
    }
    
    func testTurnONLYTURN() async {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("only_turn.sqlite")
            try createMockDatabase(at: url)
            var p: OpaquePointer?
            sqlite3_open(url.path, &p)
            sqlite3_exec(p, "DELETE FROM restricted_turns; INSERT INTO restricted_turns (from_edge, to_edge, restriction_type) VALUES (10, 25, 1);", nil, nil, nil)
            sqlite3_close(p)
            
            let db = RoutingDatabase(fileURL: url)
            let service = OfflineRoutingService(database: db)
            let route = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 0), to: CLLocationCoordinate2D(latitude: 0, longitude: 2))
            assert(route.edgeIDs == [10, 25, 53], "TurnONLYTURN: Handled ONLY_TURN properly")
        } catch {
            assert(false, "TurnONLYTURN: Failed")
        }
    }
    
    func testGeometryReconstruction() async {
        do {
            let db = RoutingDatabase(fileURL: mockDBURL)
            let service = OfflineRoutingService(database: db)
            let route = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 0), to: CLLocationCoordinate2D(latitude: 0, longitude: 1))
            assert(route.geometry.count == 2 && route.geometry[0].latitude == 0.0 && route.geometry[1].longitude == 1.0, "GeometryReconstruction: Working")
        } catch {
            assert(false, "GeometryReconstruction: Failed")
        }
    }
    
    func testDistanceAndETA() async {
        do {
            let db = try buildDirectGraph()
            let service = OfflineRoutingService(database: db)
            let route = try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 0), to: CLLocationCoordinate2D(latitude: 0, longitude: 3))
            assert(route.totalDistanceMeters == 3000 && round(route.estimatedTravelTimeSeconds) == 216, "DistanceAndETA: Correct calculations")
        } catch {
            assert(false, "DistanceAndETA: Failed")
        }
    }
    
    func testCancellation() async {
        let db = try! buildDirectGraph()
        let service = OfflineRoutingService(database: db)
        
        let task = Task {
            try await service.calculateRoute(from: CLLocationCoordinate2D(latitude: 0, longitude: 0), to: CLLocationCoordinate2D(latitude: 0, longitude: 3))
        }
        task.cancel()
        do {
            _ = try await task.value
            assert(false, "Cancellation: Should have thrown CancellationError")
        } catch is CancellationError {
            assert(true, "Cancellation: Handled gracefully")
        } catch {
            assert(false, "Cancellation: Wrong error")
        }
    }
    
    func testMonacoSmokeTest() async {
        let monacoURL = URL(fileURLWithPath: "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite")
        guard FileManager.default.fileExists(atPath: monacoURL.path) else {
            print("⚠️ SKIP: Monaco test DB not found locally.")
            return
        }
        
        do {
            let db = RoutingDatabase(fileURL: monacoURL)
            let service = OfflineRoutingService(database: db)
            let meta = try db.metadata()
            assert(meta.profile == "car", "MonacoSmokeTest: DB loaded successfully")
            
            let start = CLLocationCoordinate2D(latitude: 43.7384, longitude: 7.4246)
            let end = CLLocationCoordinate2D(latitude: 43.7400, longitude: 7.4260)
            let route = try await service.calculateRoute(from: start, to: end)
            
            assert(!route.nodeIDs.isEmpty && !route.geometry.isEmpty && route.totalDistanceMeters > 0, "MonacoSmokeTest: Successfully generated full offline route")
        } catch {
            assert(false, "MonacoSmokeTest: Failed with error \\(error)")
        }
    }
    
    private func buildDirectGraph() throws -> RoutingDatabase {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct.sqlite")
        try createMockDatabase(at: url)
        var p: OpaquePointer?
        sqlite3_open(url.path, &p)
        sqlite3_exec(p, "DELETE FROM restricted_turns;", nil, nil, nil)
        sqlite3_close(p)
        return RoutingDatabase(fileURL: url)
    }
}

Task { let (_, failed) = await RoutingTests.shared.runAllTests(); if failed > 0 { exit(1) } else { exit(0) } }; RunLoop.main.run()
