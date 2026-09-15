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
    
    func validate() throws {
        try withDB { db in
            // 1. Integrity check
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    if let text = sqlite3_column_text(statement, 0) {
                        let result = String(cString: text).lowercased()
                        if result != "ok" {
                            sqlite3_finalize(statement)
                            throw RoutingError.databaseError("Integrity check failed: \(result)")
                        }
                    }
                }
            } else {
                throw RoutingError.databaseError("Failed to prepare integrity check")
            }
            sqlite3_finalize(statement)
            
            // 2. Schema check - ensure required tables exist
            let requiredTables = ["metadata", "region", "nodes", "edges", "edge_geometry", "turn_restrictions", "restricted_turns", "rtree_nodes"]
            for table in requiredTables {
                let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='\(table)';"
                if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                    if sqlite3_step(statement) != SQLITE_ROW {
                        sqlite3_finalize(statement)
                        throw RoutingError.databaseError("Missing required table: \(table)")
                    }
                }
                sqlite3_finalize(statement)
            }
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
