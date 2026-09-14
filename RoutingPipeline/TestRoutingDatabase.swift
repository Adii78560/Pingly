import Foundation
import SQLite3
import CoreLocation

// Copying RoutingDatabase code here just for standalone CLI testing
enum RoutingDatabaseError: Error {
    case connectionFailed
    case queryFailed(String)
    case notFound
    case invalidData
}

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
}

struct RoutingNode {
    var id: Int64
    var coordinate: CLLocationCoordinate2D
}

struct RoutingNeighbor {
    var edgeId: Int64
    var toNodeId: Int64
    var lengthMeters: Double
    var speedKph: Int
}

struct RoutingRestriction {
    var toEdgeId: Int64
    var type: Int
}

class RoutingDatabase {
    private var db: OpaquePointer?
    
    init(fileURL: URL) throws {
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            throw RoutingDatabaseError.connectionFailed
        }
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    func metadata() throws -> RoutingMetadata {
        var schemaVersion = ""
        var graphVersion = ""
        var regionId = ""
        var regionName = ""
        var profile = ""
        var nodeCount = 0
        var edgeCount = 0
        
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
        }
        sqlite3_finalize(statement)
        return RoutingMetadata(schemaVersion: schemaVersion, graphVersion: graphVersion, regionId: regionId, regionName: regionName, profile: profile, nodeCount: nodeCount, edgeCount: edgeCount)
    }
    
    func region() throws -> RoutingRegion {
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
        guard let r = region else { throw RoutingDatabaseError.notFound }
        return r
    }
    
    func nearestNode(to coordinate: CLLocationCoordinate2D, searchRadiusDegrees: Double = 0.05) throws -> RoutingNode {
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
        var bestNode: RoutingNode?
        var minDistance = Double.greatestFiniteMagnitude
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, minLat)
            sqlite3_bind_double(statement, 2, maxLat)
            sqlite3_bind_double(statement, 3, minLon)
            sqlite3_bind_double(statement, 4, maxLon)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let lat = sqlite3_column_double(statement, 1)
                let lon = sqlite3_column_double(statement, 2)
                
                let candidateLoc = CLLocation(latitude: lat, longitude: lon)
                let targetLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let distance = candidateLoc.distance(from: targetLoc)
                
                if distance < minDistance {
                    minDistance = distance
                    bestNode = RoutingNode(id: id, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
            }
        }
        sqlite3_finalize(statement)
        guard let node = bestNode else { throw RoutingDatabaseError.notFound }
        return node
    }
    
    func neighbors(of nodeId: Int64) throws -> [RoutingNeighbor] {
        let query = "SELECT edge_id, v, length_m, speed_kph FROM edges WHERE u = ?;"
        var statement: OpaquePointer?
        var neighbors = [RoutingNeighbor]()
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, nodeId)
            while sqlite3_step(statement) == SQLITE_ROW {
                neighbors.append(RoutingNeighbor(
                    edgeId: sqlite3_column_int64(statement, 0),
                    toNodeId: sqlite3_column_int64(statement, 1),
                    lengthMeters: sqlite3_column_double(statement, 2),
                    speedKph: Int(sqlite3_column_int(statement, 3))
                ))
            }
        }
        sqlite3_finalize(statement)
        return neighbors
    }
    
    func edgeGeometry(for edgeId: Int64) throws -> [CLLocationCoordinate2D] {
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
                                
                                let lat = Double(latInt) / 1_000_000.0
                                let lon = Double(lonInt) / 1_000_000.0
                                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                                offset += 8
                            }
                        }
                    }
                }
            }
        }
        sqlite3_finalize(statement)
        return coords
    }
}

// ---- TEST HARNESS ----
do {
    let dbURL = URL(fileURLWithPath: "monaco.rgraph.sqlite")
    let db = try RoutingDatabase(fileURL: dbURL)
    
    let meta = try db.metadata()
    print("Metadata: \\(meta)")
    
    let reg = try db.region()
    print("Region bounds: \\(reg.minLat), \\(reg.minLon) to \\(reg.maxLat), \\(reg.maxLon)")
    
    // Monaco roughly 43.73, 7.42
    let coord = CLLocationCoordinate2D(latitude: 43.7384, longitude: 7.4246)
    print("Snapping for coordinate \\(coord.latitude), \\(coord.longitude)")
    
    let nearest = try db.nearestNode(to: coord)
    print("Nearest Node ID: \\(nearest.id) at \\(nearest.coordinate.latitude), \\(nearest.coordinate.longitude)")
    
    let neighbors = try db.neighbors(of: nearest.id)
    print("Neighbors (\\(neighbors.count)):")
    for n in neighbors {
        print("  -> Node \\(n.toNodeId) via Edge \\(n.edgeId), length \\(n.lengthMeters)m @ \\(n.speedKph)kph")
        
        let geom = try db.edgeGeometry(for: n.edgeId)
        print("     Geometry points: \\(geom.count)")
        if let first = geom.first {
            print("       Start: \\(first.latitude), \\(first.longitude)")
        }
        if let last = geom.last {
            print("       End: \\(last.latitude), \\(last.longitude)")
        }
    }
    
    print("SUCCESS: Swift SQLite RoutingDatabase parsed correctly.")
} catch {
    print("ERROR: \\(error)")
}
