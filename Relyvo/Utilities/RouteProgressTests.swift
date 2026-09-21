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
        } else {
            failed += 1
        }
    }
    
    public func runAllTests() async -> (passed: Int, failed: Int) {
        passed = 0
        failed = 0
        
        await testProjectionMidpoint()
        await testProjectionEndpoint()
        await testProgressCalculation()
        await testBearingWraparound()
        await testManeuverClassification()
        await testOffRouteHysteresis()
        await testRerouteCooldown()
        await testArrivalDetection()
        await testMonacoSmokeTest()
        
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
        let prog = try? await service.updateProgress(location: loc, heading: nil as Double?)
        
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
        let prog = try? await service.updateProgress(location: loc, heading: nil as Double?)
        
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
        
        var prog = try? await service.updateProgress(location: loc, heading: nil as Double?)
        assert(prog?.isOffRoute == true, "Hysteresis: Triggered off-route")
        
        // Move back slightly to 20 meters (below enter, but above exit threshold 15)
        loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.00020, longitude: 0.005),
                         altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        prog = try? await service.updateProgress(location: loc, heading: nil as Double?)
        assert(prog?.isOffRoute == true, "Hysteresis: Maintained off-route (hysteresis active)")
        
        // Move back fully to 5 meters (below exit threshold 15)
        loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.00004, longitude: 0.005),
                         altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        prog = try? await service.updateProgress(location: loc, heading: nil as Double?)
        assert(prog?.isOffRoute == false, "Hysteresis: Exited off-route successfully")
    }
    
    private func testRerouteCooldown() async {
        let service = createMockService()
        await service.setRoute(createStraightMockRoute())
        
        // Force off route
        let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.00050, longitude: 0.005),
                             altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        
        let _ = try? await service.updateProgress(location: loc, heading: nil) // offRouteCandidate
        let _ = try? await service.updateProgress(location: loc, heading: nil) // offRoute
        
        // Wait for the async reroute task to fail
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        // It should attempt a reroute and fail (db is empty), placing stateMachine in .offRoute
        let state = await service.stateMachine
        assert(state == .offRoute, "RerouteCooldown: Engine attempted reroute and reverted to offRoute on failure")
        
        // Update again immediately
        let _ = try? await service.updateProgress(location: loc, heading: nil as Double?)
        let state2 = await service.stateMachine
        assert(state2 == .offRoute, "RerouteCooldown: Kept state without spamming reroute task")
    }
    
    private func testArrivalDetection() async {
        let service = createMockService()
        await service.setRoute(createStraightMockRoute())
        
        // Destination is 0.0, 0.01
        let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0099),
                             altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        let prog = try? await service.updateProgress(location: loc, heading: nil as Double?)
        
        assert(prog?.isArrived == true, "ArrivalDetection: Arrived near destination")
        assert(prog?.remainingDistanceMeters == 0, "ArrivalDetection: Remaining distance clamped to 0")
    }
    
    private func testMonacoSmokeTest() async {
        let monacoURL = URL(fileURLWithPath: "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite")
        guard FileManager.default.fileExists(atPath: monacoURL.path) else {
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
            let prog = try await service.updateProgress(location: loc, heading: nil as Double?)
            
            assert(prog != nil, "MonacoProgress: Successfully updated progress on real route")
            assert(prog?.isOffRoute == false, "MonacoProgress: Started on route")
            if let m = prog?.nextManeuver {
                assert(m.type != .start, "MonacoProgress: Extracted a valid upcoming maneuver")
            }
        } catch RoutingError.noRouteFound {
        } catch {
            assert(false, "MonacoProgress: Failed \(error)")
        }
    }
}

// End of File
