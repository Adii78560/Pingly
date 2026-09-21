//
//  NavigationUITests.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import Foundation
import CoreLocation
import SwiftUI

@MainActor
final class NavigationUITests {
    
    // Simulates standard Navigation UI interactions to ensure no crash and logical mode switching
    static func runAllTests() async throws {
        
        let start = CFAbsoluteTimeGetCurrent()
        var passed = 0
        var failed = 0
        
        func verify(_ condition: Bool, _ message: String) {
            if condition {
                passed += 1
            } else {
                failed += 1
            }
        }
        
        let dbPath = "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite"
        let hasRouting = FileManager.default.fileExists(atPath: dbPath)
        
        // Setup
        let viewModel = NavigationViewModel()
        
        // 1. Initial State
        verify(viewModel.navigationMode == .directTarget, "Initial mode is directTarget")
        
        // 2. Direct Target (SOS fallback if no route)
        let sosTarget = NavigationTarget(
            id: UUID().uuidString,
            displayName: "SOS Beacon",
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude: nil,
            accuracy: 5.0,
            timestamp: Date(),
            sequenceNumber: 1,
            targetType: .sos
        )
        
        viewModel.setTarget(sosTarget)
        
        // Allow async task for attemptRoadRouting to fail/complete
        try await Task.sleep(nanoseconds: 500_000_000)
        
        verify(viewModel.target?.id == sosTarget.id, "Target is set to SOS")
        verify(viewModel.navigationMode == .directTarget, "SOS defaults/falls back to directTarget when routing fails (0,0 is unroutable)")
        verify(viewModel.isNavigating == true, "Navigation is active")
        
        // 3. Routable Target
        if hasRouting {
            let routableTarget = NavigationTarget(
                id: UUID().uuidString,
                displayName: "Hotel de Paris",
                coordinate: CLLocationCoordinate2D(latitude: 43.7391, longitude: 7.4267),
                altitude: nil,
                accuracy: 10.0,
                timestamp: Date(),
                sequenceNumber: 2,
                targetType: .waypoint
            )
            
            // Mock Location inside Monaco to allow routing to succeed
            LocationService.shared.locationManager(CLLocationManager(), didUpdateLocations: [CLLocation(latitude: 43.7314, longitude: 7.4201)])
            
            viewModel.setTarget(routableTarget)
            
            // Wait for A* routing to complete
            try await Task.sleep(nanoseconds: 1_500_000_000)
            
            verify(viewModel.navigationMode == .roadRoute, "Navigation mode switched to roadRoute")
            verify(viewModel.activeRoute != nil, "Active route is present")
            verify(viewModel.isNavigating == true, "Navigation is active")
            
            // Simulate GPS Update to trigger RouteProgress
            LocationService.shared.locationManager(CLLocationManager(), didUpdateLocations: [CLLocation(latitude: 43.7315, longitude: 7.4202)])
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            verify(viewModel.routeProgress != nil, "RouteProgress is generated")
            verify(viewModel.routeState == .onRoute || viewModel.routeState == .newRoute, "Route State is ON_ROUTE")
            
            // 4. Off-Route Simulation
            LocationService.shared.locationManager(CLLocationManager(), didUpdateLocations: [CLLocation(latitude: 43.7500, longitude: 7.4500)]) // Far away
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            verify(viewModel.routeProgress?.isOffRoute == true, "Off-Route detected")
        } else {
        }
        
        viewModel.stopNavigation()
        verify(viewModel.isNavigating == false, "Navigation stopped correctly")
        
        let end = CFAbsoluteTimeGetCurrent()
    }
}
