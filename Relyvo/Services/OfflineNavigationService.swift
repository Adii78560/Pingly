//
//  OfflineNavigationService.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import Foundation
import CoreLocation
import Combine
import os

/// Real-time calculation engine transforming raw GPS coordinates & compass azimuths
/// into human-actionable off-grid tactical guidance.
@MainActor
final class OfflineNavigationService: ObservableObject {
    
    static let shared = OfflineNavigationService()
    
    // MARK: - Published Navigation State
    @Published private(set) var activeTarget: NavigationTarget?
    @Published private(set) var currentVector: RelativeNavigationVector?
    @Published private(set) var isNavigating: Bool = false
    @Published private(set) var isCompassCalibrated: Bool = true
    
    // Recent distance sample history for trend analysis (Closing / Opening)
    private var distanceHistory: [(distance: Double, timestamp: Date)] = []
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupLocationSubscriptions()
    }
    
    // MARK: - Subscriptions to LocationService
    private func setupLocationSubscriptions() {
        // Recalculate whenever GPS coordinate or continuous heading changes
        Publishers.CombineLatest(
            LocationService.shared.$currentCoordinate,
            LocationService.shared.$smoothedHeading
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] coord, heading in
            guard let self = self, let target = self.activeTarget else { return }
            self.recalculateVector(userCoord: coord, userHeading: heading, target: target)
        }
        .store(in: &cancellables)
    }
    
    // MARK: - Public Navigation Target Controls
    
    /// Set or switch the active navigation target (Peer, SOS, Waypoint, Return-to-Start)
    func startNavigating(to target: NavigationTarget) {
        self.activeTarget = target
        self.isNavigating = true
        self.distanceHistory.removeAll()
        
        // Ensure location updates & compass sensor are running
        LocationService.shared.startSharingLocation()
        LocationService.shared.startUpdatingHeading()
        
        // Immediate calculation pass
        recalculateVector(
            userCoord: LocationService.shared.currentCoordinate,
            userHeading: LocationService.shared.smoothedHeading,
            target: target
        )
        
    }
    
    /// Update existing target's coordinates when fresh P2P mesh packets arrive
    func updateTargetCoordinate(_ target: NavigationTarget) {
        guard let current = self.activeTarget, current.id == target.id else { return }
        self.activeTarget = target
        recalculateVector(
            userCoord: LocationService.shared.currentCoordinate,
            userHeading: LocationService.shared.smoothedHeading,
            target: target
        )
    }
    
    /// Stop current active navigation session
    func stopNavigating() {
        self.activeTarget = nil
        self.currentVector = nil
        self.isNavigating = false
        self.distanceHistory.removeAll()
        CompassHapticManager.shared.resetState()
    }
    
    // MARK: - Core Calculation Engine
    
    private func recalculateVector(userCoord: CLLocationCoordinate2D?, userHeading: Double, target: NavigationTarget) {
        guard let userCoord = userCoord, isValidCoordinate(userCoord), isValidCoordinate(target.coordinate) else {
            // Signal acquiring state
            self.currentVector = RelativeNavigationVector(
                distanceMeters: 0,
                initialBearingDegrees: 0,
                relativeBearingDegrees: 0,
                userHeadingDegrees: userHeading,
                cardinal: .north,
                instruction: .acquiringSignal,
                isAligned: false,
                isArrived: false,
                distanceTrend: .stationary,
                formattedDistance: "---"
            )
            return
        }
        
        // 1. Calculate Great-Circle Distance (Haversine)
        let distance = calculateDistance(from: userCoord, to: target.coordinate)
        
        // 2. Calculate Forward Initial True Bearing (0...360)
        let initialBearing = calculateBearing(from: userCoord, to: target.coordinate)
        
        // 3. Calculate Relative Bearing offset from continuous user heading (-180...+180)
        let normalizedUserHeading = (userHeading.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)
        let rawRelative = initialBearing - normalizedUserHeading
        let relativeBearing = CircularAngleHelper.shortestAngularDifference(from: 0, to: rawRelative)
        
        // 4. Determine Cardinal Sector
        let cardinal = CardinalDirection(bearing: initialBearing)
        
        // 5. Calculate Distance Trend (Closing / Opening)
        let trend = evaluateDistanceTrend(newDistance: distance)
        
        // 6. Evaluate Human-Readable Navigation Instruction
        let isArrived = distance <= 10.0
        let isAligned = abs(relativeBearing) <= 8.0
        let instruction: NavigationInstruction
        
        if target.staleness == .expired {
            instruction = .locationExpired
        } else if isArrived {
            instruction = .arrived
        } else if isAligned {
            instruction = .faceTarget
        } else if relativeBearing > 8.0 && relativeBearing <= 30.0 {
            instruction = .turnSlightlyRight(degrees: Int(relativeBearing.rounded()))
        } else if relativeBearing > 30.0 && relativeBearing <= 75.0 {
            instruction = .turnRight(degrees: Int(relativeBearing.rounded()))
        } else if relativeBearing > 75.0 && relativeBearing <= 135.0 {
            instruction = .turnSharplyRight(degrees: Int(relativeBearing.rounded()))
        } else if relativeBearing >= -30.0 && relativeBearing < -8.0 {
            instruction = .turnSlightlyLeft(degrees: Int(abs(relativeBearing).rounded()))
        } else if relativeBearing >= -75.0 && relativeBearing < -30.0 {
            instruction = .turnLeft(degrees: Int(abs(relativeBearing).rounded()))
        } else if relativeBearing >= -135.0 && relativeBearing < -75.0 {
            instruction = .turnSharplyLeft(degrees: Int(abs(relativeBearing).rounded()))
        } else {
            instruction = .turnAround(degrees: Int(abs(relativeBearing).rounded()))
        }
        
        // 7. Format Distance
        let formattedDist = formatDistance(meters: distance)
        
        let vector = RelativeNavigationVector(
            distanceMeters: distance,
            initialBearingDegrees: initialBearing,
            relativeBearingDegrees: relativeBearing,
            userHeadingDegrees: normalizedUserHeading,
            cardinal: cardinal,
            instruction: instruction,
            isAligned: isAligned,
            isArrived: isArrived,
            distanceTrend: trend,
            formattedDistance: formattedDist
        )
        
        self.currentVector = vector
        
        // 8. Feed Directional Haptic Subsystem
        CompassHapticManager.shared.evaluateDirectionalHaptic(
            relativeBearing: relativeBearing,
            distanceMeters: distance,
            isArrived: isArrived
        )
    }
    
    // MARK: - Mathematical Helpers
    
    /// Calculate standard Great-Circle Haversine distance in meters
    func calculateDistance(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = source.latitude * .pi / 180.0
        let lon1 = source.longitude * .pi / 180.0
        let lat2 = destination.latitude * .pi / 180.0
        let lon2 = destination.longitude * .pi / 180.0
        
        let dLat = lat2 - lat1
        let dLon = lon2 - lon1
        
        let a = sin(dLat / 2.0) * sin(dLat / 2.0) +
                cos(lat1) * cos(lat2) *
                sin(dLon / 2.0) * sin(dLon / 2.0)
        let c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a))
        
        return earthRadiusMeters * c
    }
    
    /// Calculate forward initial true bearing from source to destination (0...360°)
    func calculateBearing(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
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
    
    /// Validate coordinate ranges and finite numerical values
    func isValidCoordinate(_ coord: CLLocationCoordinate2D) -> Bool {
        guard !coord.latitude.isNaN && !coord.longitude.isNaN else { return false }
        guard coord.latitude >= -90.0 && coord.latitude <= 90.0 else { return false }
        guard coord.longitude >= -180.0 && coord.longitude <= 180.0 else { return false }
        // Reject null island 0,0 if uninitialized
        if abs(coord.latitude) < 0.000001 && abs(coord.longitude) < 0.000001 {
            return false
        }
        return true
    }
    
    /// Format distance for human presentation
    func formatDistance(meters: Double) -> String {
        if meters < 1000 {
            return String(format: "%.0f m", meters)
        } else if meters < 10000 {
            return String(format: "%.2f km", meters / 1000.0)
        } else {
            return String(format: "%.1f km", meters / 1000.0)
        }
    }
    
    /// Track distance delta over time to determine if closing in or moving away
    private func evaluateDistanceTrend(newDistance: Double) -> RelativeNavigationVector.DistanceTrend {
        let now = Date()
        distanceHistory.append((distance: newDistance, timestamp: now))
        // Keep last 10 seconds of distance samples
        distanceHistory = distanceHistory.filter { now.timeIntervalSince($0.timestamp) <= 10.0 }
        
        guard distanceHistory.count >= 3, let first = distanceHistory.first else {
            return .stationary
        }
        
        let deltaDistance = newDistance - first.distance
        let deltaTime = now.timeIntervalSince(first.timestamp)
        
        guard deltaTime >= 2.0 else { return .stationary }
        
        let velocityMetersPerSec = deltaDistance / deltaTime // Positive = Opening, Negative = Closing
        
        if velocityMetersPerSec < -0.3 {
            return .closing
        } else if velocityMetersPerSec > 0.3 {
            return .opening
        } else {
            return .stationary
        }
    }
}
