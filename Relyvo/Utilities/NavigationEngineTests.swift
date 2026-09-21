//
//  NavigationEngineTests.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import Foundation
import CoreLocation
import os

/// Automated Verification Suite for Offline Navigation, Tactical Math, Staleness, and Breadcrumb Engines
final class NavigationEngineTests {
    
    static let shared = NavigationEngineTests()
    
    private init() {}
    
    @MainActor
    func runAllNavigationTests() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        
        func assert(_ condition: Bool, _ message: String) {
            if condition {
                passed += 1
            } else {
                failed += 1
            }
        }
        
        
        let nav = OfflineNavigationService.shared
        
        // 1. Distance Calculation (Haversine WGS84 Benchmarks)
        // SF to NYC (~4130 km)
        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let nyc = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let sfToNycDist = nav.calculateDistance(from: sf, to: nyc)
        assert(sfToNycDist > 4_100_000 && sfToNycDist < 4_200_000, "Great-Circle distance calculation accurate for SF to NYC (~4,130km)")
        
        // 100-meter local offset
        let p1 = CLLocationCoordinate2D(latitude: 30.9000, longitude: 75.8500)
        let p2 = CLLocationCoordinate2D(latitude: 30.9009, longitude: 75.8500) // ~100m North
        let localDist = nav.calculateDistance(from: p1, to: p2)
        assert(localDist >= 95.0 && localDist <= 105.0, "Short-range local distance calculation accurate (~100m)")
        
        // 2. Initial True Bearing Calculations
        // Due North
        let targetNorth = CLLocationCoordinate2D(latitude: 31.0000, longitude: 75.8500)
        let bearingNorth = nav.calculateBearing(from: p1, to: targetNorth)
        assert(abs(bearingNorth - 0.0) < 0.1 || abs(bearingNorth - 360.0) < 0.1, "Target directly North yields 0° bearing (got \(bearingNorth)°)")
        
        // Due East
        let targetEast = CLLocationCoordinate2D(latitude: 30.9000, longitude: 76.8500)
        let bearingEast = nav.calculateBearing(from: p1, to: targetEast)
        assert(abs(bearingEast - 90.0) < 1.0, "Target directly East yields 90° bearing (got \(bearingEast)°)")
        
        // Due South
        let targetSouth = CLLocationCoordinate2D(latitude: 29.9000, longitude: 75.8500)
        let bearingSouth = nav.calculateBearing(from: p1, to: targetSouth)
        assert(abs(bearingSouth - 180.0) < 0.5, "Target directly South yields 180° bearing (got \(bearingSouth)°)")
        
        // Due West
        let targetWest = CLLocationCoordinate2D(latitude: 30.9000, longitude: 74.8500)
        let bearingWest = nav.calculateBearing(from: p1, to: targetWest)
        assert(abs(bearingWest - 270.0) < 1.0, "Target directly West yields 270° bearing (got \(bearingWest)°)")
        
        // 3. Cardinal & Intercardinal Sectors
        assert(CardinalDirection(bearing: 0.0) == .north, "0° maps to NORTH")
        assert(CardinalDirection(bearing: 45.0) == .northEast, "45° maps to NORTHEAST")
        assert(CardinalDirection(bearing: 90.0) == .east, "90° maps to EAST")
        assert(CardinalDirection(bearing: 135.0) == .southEast, "135° maps to SOUTHEAST")
        assert(CardinalDirection(bearing: 180.0) == .south, "180° maps to SOUTH")
        assert(CardinalDirection(bearing: 225.0) == .southWest, "225° maps to SOUTHWEST")
        assert(CardinalDirection(bearing: 270.0) == .west, "270° maps to WEST")
        assert(CardinalDirection(bearing: 315.0) == .northWest, "315° maps to NORTHWEST")
        assert(CardinalDirection(bearing: 359.0) == .north, "359° maps to NORTH")
        
        // 4. Heading Wraparound & North Crossing Math
        let delta1 = CircularAngleHelper.shortestAngularDifference(from: 355.0, to: 5.0)
        assert(delta1 == 10.0, "North crossing clockwise 355° -> 5° yields +10° delta")
        
        let delta2 = CircularAngleHelper.shortestAngularDifference(from: 5.0, to: 355.0)
        assert(delta2 == -10.0, "North crossing counter-clockwise 5° -> 355° yields -10° delta")
        
        // 5. International Date Line
        let westOfDateLine = CLLocationCoordinate2D(latitude: 0.0, longitude: 179.0)
        let eastOfDateLine = CLLocationCoordinate2D(latitude: 0.0, longitude: -179.0)
        let dateLineDist = nav.calculateDistance(from: westOfDateLine, to: eastOfDateLine)
        assert(dateLineDist < 300_000, "Date line crossing distance is short (~222km, not 39,000km)")
        
        // 6. Target Staleness Lifecycle
        let now = Date()
        let liveTarget = NavigationTarget(
            id: "target_1",
            displayName: "Live Target",
            coordinate: p1,
            timestamp: now.addingTimeInterval(-4)
        )
        assert(liveTarget.staleness == .live, "Target updated 4s ago is .live")
        
        let recentTarget = NavigationTarget(
            id: "target_2",
            displayName: "Recent Target",
            coordinate: p1,
            timestamp: now.addingTimeInterval(-35)
        )
        assert(recentTarget.staleness == .recent, "Target updated 35s ago is .recent")
        
        let staleTarget = NavigationTarget(
            id: "target_3",
            displayName: "Stale Target",
            coordinate: p1,
            timestamp: now.addingTimeInterval(-180)
        )
        assert(staleTarget.staleness == .stale, "Target updated 3m ago is .stale")
        
        let expiredTarget = NavigationTarget(
            id: "target_4",
            displayName: "Expired Target",
            coordinate: p1,
            timestamp: now.addingTimeInterval(-400)
        )
        assert(expiredTarget.staleness == .expired, "Target updated >5m ago is .expired")
        assert(!expiredTarget.staleness.isTrustworthy, "Expired target is marked not trustworthy")
        
        // 7. Directional Haptic States
        assert(DirectionalHapticState.state(for: 0.0, isArrived: true) == .arrived, "Arrival distance triggers .arrived state")
        assert(DirectionalHapticState.state(for: 4.0, isArrived: false) == .targetCenter, "Small relative bearing (4°) triggers .targetCenter")
        assert(DirectionalHapticState.state(for: 30.0, isArrived: false) == .targetSlightRight, "30° relative bearing triggers .targetSlightRight")
        assert(DirectionalHapticState.state(for: 70.0, isArrived: false) == .targetRight, "70° relative bearing triggers .targetRight")
        assert(DirectionalHapticState.state(for: -30.0, isArrived: false) == .targetSlightLeft, "-30° relative bearing triggers .targetSlightLeft")
        assert(DirectionalHapticState.state(for: -70.0, isArrived: false) == .targetLeft, "-70° relative bearing triggers .targetLeft")
        assert(DirectionalHapticState.state(for: 170.0, isArrived: false) == .targetBehind, "170° relative bearing triggers .targetBehind")
        
        // 8. Adaptive Broadcasting Intervals
        let lsm = LocationShareManager.shared
        assert(lsm.calculateAdaptiveInterval(speedMetersPerSec: 0.1, isSOSActive: false) == 30.0, "Stationary speed (<1km/h) sets 30s broadcast interval")
        assert(lsm.calculateAdaptiveInterval(speedMetersPerSec: 0.6, isSOSActive: false) == 15.0, "Slow walking speed (2.1km/h) sets 15s broadcast interval")
        assert(lsm.calculateAdaptiveInterval(speedMetersPerSec: 1.4, isSOSActive: false) == 8.0, "Walking speed (5km/h) sets 8s broadcast interval")
        assert(lsm.calculateAdaptiveInterval(speedMetersPerSec: 8.0, isSOSActive: false) == 3.0, "Vehicle speed (>20km/h) sets 3s broadcast interval")
        assert(lsm.calculateAdaptiveInterval(speedMetersPerSec: 0.0, isSOSActive: true) == 2.0, "Active SOS overrides speed and sets 2s broadcast interval")
        
        // 9. Coordinate Validation
        assert(nav.isValidCoordinate(CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)), "Standard coordinate is valid")
        assert(!nav.isValidCoordinate(CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)), "Null island 0,0 is rejected as uninitialized")
        assert(!nav.isValidCoordinate(CLLocationCoordinate2D(latitude: 95.0, longitude: 10.0)), "Out-of-range latitude >90 is rejected")
        
        // 10. Return to Start Target Generation
        let breadcrumbService = BreadcrumbTrackingService.shared
        breadcrumbService.startTracking(name: "Test Trail")
        let returnTarget = breadcrumbService.createReturnToStartTarget()
        breadcrumbService.stopTracking()
        assert(returnTarget?.targetType == .returnToStart, "Return-to-Start target correctly generated as .returnToStart type")
        
        
        return (passed, failed)
    }
}
