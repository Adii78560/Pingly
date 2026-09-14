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
