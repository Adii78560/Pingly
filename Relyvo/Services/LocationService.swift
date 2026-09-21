//
//  LocationService.swift
//  Relayn
//
//  Created by Senior iOS Developer on 13/08/26.
//

import Foundation
import CoreLocation
import Combine
import UIKit
import os

/// Comprehensive CoreLocation service for offline GPS acquisition & mesh location sharing
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    
    static let shared = LocationService()
    
    @Published private(set) var currentCoordinate: CLLocationCoordinate2D?
    @Published private(set) var currentAltitude: Double?
    @Published private(set) var currentAccuracy: Double?
    @Published private(set) var currentSpeed: Double?
    @Published private(set) var currentCourse: Double?
    @Published private(set) var currentHeading: Double?
    @Published private(set) var previousRawHeading: Double?
    @Published private(set) var smoothedHeading: Double = 0.0
    @Published private(set) var headingAccuracy: Double = 0.0
    @Published private(set) var lastLocationTimestamp: Date?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isSharingLocation: Bool = false
    @Published var showPermissionDeniedAlert: Bool = false
    
    var currentLocation: CLLocationCoordinate2D? {
        return currentCoordinate
    }
    
    private let locationManager = CLLocationManager()
    private var oneShotCompletion: ((CLLocation?) -> Void)?
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5 // Update every 5 meters for relative location & navigation
        locationManager.headingFilter = kCLHeadingFilterNone // Real-time hardware stream
        locationManager.headingOrientation = .portrait
        locationManager.pausesLocationUpdatesAutomatically = false
        
        // Configure background location updates if bundle declares location background mode
        let backgroundModes = Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String] ?? []
        if backgroundModes.contains("location") {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }
        
        // authorizationStatus is evaluated via delegate callbacks to prevent main thread warnings
        
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    @objc private func appDidEnterBackground() {
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50.0
        AppLogger.location.info("[LOCATION_POWER] Throttled GPS accuracy for background battery conservation.")
    }
    
    @objc private func appWillEnterForeground() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5.0
        AppLogger.location.info("[LOCATION_POWER] Restored high-precision GPS tracking in foreground.")
    }
    
    // MARK: - Permission Handling
    
    func requestLocationPermission() {
        switch authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.showPermissionDeniedAlert = true
            }
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            break
        }
    }
    
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
    
    // MARK: - Location & Compass Heading Lifecycle
    
    func startUpdatingHeading() {
#if targetEnvironment(simulator)
        DispatchQueue.main.async {
            self.currentHeading = 0.0
            self.previousRawHeading = nil
            self.smoothedHeading = 0.0
            self.headingAccuracy = 5.0
        }
#endif
        guard CLLocationManager.headingAvailable() else {
            return
        }
        locationManager.startUpdatingHeading()
    }
    
    func stopUpdatingHeading() {
        locationManager.stopUpdatingHeading()
    }
    
    func startSharingLocation() {
        guard !isSharingLocation else { return }
        
        guard CLLocationManager.locationServicesEnabled() else {
            DispatchQueue.main.async {
                self.showPermissionDeniedAlert = true
            }
            return
        }
        
        let status = locationManager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            self.isSharingLocation = true
            locationManager.startUpdatingLocation()
            startUpdatingHeading()
        } else {
            requestLocationPermission()
        }
    }
    
    func stopSharingLocation() {
        guard isSharingLocation else { return }
        self.isSharingLocation = false
        locationManager.stopUpdatingLocation()
        stopUpdatingHeading()
    }
    
    /// One-shot offline GPS coordinate snapshot for immediate location sharing
    func getCurrentLocationSnapshot(completion: @escaping (CLLocation?) -> Void) {
#if targetEnvironment(simulator)
        if locationManager.location == nil {
            let mockLoc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                altitude: 10.0,
                horizontalAccuracy: 5.0,
                verticalAccuracy: 5.0,
                timestamp: Date()
            )
            completion(mockLoc)
            return
        }
#endif
        if let location = locationManager.location, Date().timeIntervalSince(location.timestamp) < 30 {
            completion(location)
            return
        }
        
        self.oneShotCompletion = completion
        let status = locationManager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            locationManager.requestLocation()
        } else {
            requestLocationPermission()
        }
    }
    
    // MARK: - Peer Location Cache
    
    private var peerLocations: [UUID: CLLocation] = [:]
    private let peerLocationsLock = NSLock()
    
    /// Updates cached coordinate for a remote peer node.
    func updatePeerLocation(nodeID: UUID, location: CLLocation) {
        peerLocationsLock.lock()
        peerLocations[nodeID] = location
        peerLocationsLock.unlock()
    }
    
    /// Retrieves cached coordinate for a remote peer node.
    func getPeerLocation(nodeID: UUID) -> CLLocation? {
        peerLocationsLock.lock()
        defer { peerLocationsLock.unlock() }
        return peerLocations[nodeID]
    }
    
    /// Relative Vector Computation:
    /// Checks `peerLocations[targetID]`. If live coordinates are missing, falls back to fallback coordinate.
    func relativeVector(to targetID: UUID, fallbackLat: Double? = nil, fallbackLon: Double? = nil) -> (distanceMeters: Double, initialBearing: Double, relativeBearing: Double, distanceFormatted: String, compassDirection: String)? {
        if let cachedLoc = getPeerLocation(nodeID: targetID) {
            return relativeBearing(toLat: cachedLoc.coordinate.latitude, lon: cachedLoc.coordinate.longitude)
        } else if let lat = fallbackLat, let lon = fallbackLon {
            return relativeBearing(toLat: lat, lon: lon)
        }
        return nil
    }
    
    // MARK: - Distance & Bearing Calculation Helpers
    
    /// Calculates relative direction angle (0...360 degrees) accounting for user heading and initial bearing
    func relativeBearing(toLat lat: Double, lon: Double) -> (distanceMeters: Double, initialBearing: Double, relativeBearing: Double, distanceFormatted: String, compassDirection: String)? {
        guard let userCoord = currentCoordinate else { return nil }
        let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
        let targetLoc = CLLocation(latitude: lat, longitude: lon)
        
        let meters = userLoc.distance(from: targetLoc)
        let distanceFormatted: String
        if meters < 1000 {
            distanceFormatted = String(format: "%.0f m", meters)
        } else {
            distanceFormatted = String(format: "%.1f km", meters / 1000.0)
        }
        
        let initialBearing = calculateBearing(from: userCoord, to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        let heading = currentHeading ?? 0.0
        let relBearing = (initialBearing - heading + 360.0).truncatingRemainder(dividingBy: 360.0)
        let compassDir = bearingToCompassDirection(initialBearing)
        
        return (meters, initialBearing, relBearing, distanceFormatted, compassDir)
    }
    
    /// Calculates distance and compass direction from receiver's device to target coordinates
    func distanceAndBearingFromUser(toLat lat: Double, lon: Double) -> (distanceFormatted: String, bearingDirection: String)? {
        guard let userCoord = currentCoordinate else { return nil }
        let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
        let targetLoc = CLLocation(latitude: lat, longitude: lon)
        
        let meters = userLoc.distance(from: targetLoc)
        let distanceFormatted: String
        if meters < 1000 {
            distanceFormatted = String(format: "%.0f m away", meters)
        } else {
            distanceFormatted = String(format: "%.2f km away", meters / 1000.0)
        }
        
        let bearing = calculateBearing(from: userCoord, to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        let bearingDirection = bearingToCompassDirection(bearing)
        
        return (distanceFormatted, bearingDirection)
    }
    
    public func calculateBearing(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
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
    
    private func bearingToCompassDirection(_ degrees: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees + 22.5).truncatingRemainder(dividingBy: 360.0) / 45.0)
        return directions[max(0, min(index, directions.count - 1))]
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            let isAuthorized = (manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways)
            let accuracyAuth = manager.accuracyAuthorization.rawValue
            if isAuthorized {
                if self.isSharingLocation {
                    manager.startUpdatingLocation()
                    self.startUpdatingHeading()
                }
            } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                self.isSharingLocation = false
                LocationShareManager.shared.stopAllLocalSharing(reason: "Location Permission Revoked")
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let raw = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        let accuracy = newHeading.headingAccuracy
        
        DispatchQueue.main.async {
            if self.previousRawHeading == nil {
                self.previousRawHeading = raw
                self.smoothedHeading = raw
            }
            
            self.headingAccuracy = accuracy
            
            // Calculate shortest delta between [-180, 180]
            var delta = raw - (self.previousRawHeading ?? raw)
            delta = (delta + 540).truncatingRemainder(dividingBy: 360) - 180
            
            // Dynamic Alpha: Instant tracking for intentional turns, gentle damping for micro-jitter
            let absDelta = abs(delta)
            let dynamicAlpha: Double
            if absDelta > 15.0 {
                dynamicAlpha = 0.90 // Fast flick/turn: snap instantly with 0 lag
            } else if absDelta > 5.0 {
                dynamicAlpha = 0.65 // Normal body turning: responsive and smooth
            } else {
                dynamicAlpha = 0.25 // Holding still: damp sensor jitter & noise
            }
            
            self.smoothedHeading = (self.smoothedHeading + (delta * dynamicAlpha)).truncatingRemainder(dividingBy: 360)
            if self.smoothedHeading < 0 { self.smoothedHeading += 360 }
            
            self.previousRawHeading = raw
            self.currentHeading = self.smoothedHeading
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let age = Date().timeIntervalSince(location.timestamp)
        DispatchQueue.main.async {
            self.currentCoordinate = location.coordinate
            self.currentAltitude = location.altitude
            self.currentAccuracy = location.horizontalAccuracy
            self.currentSpeed = location.speed >= 0 ? location.speed : nil
            self.currentCourse = location.course >= 0 ? location.course : nil
            self.lastLocationTimestamp = location.timestamp
            
            LocationShareManager.shared.checkUrgentMovementTrigger(
                newCoord: location.coordinate,
                newHeading: self.currentHeading,
                speed: self.currentSpeed
            )
            
            if let completion = self.oneShotCompletion {
                completion(location)
                self.oneShotCompletion = nil
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let completion = self.oneShotCompletion {
            completion(locationManager.location)
            self.oneShotCompletion = nil
        }
    }
}
