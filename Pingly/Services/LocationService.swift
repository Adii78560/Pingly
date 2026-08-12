//
//  LocationService.swift
//  Pingly
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
        locationManager.distanceFilter = 10 // Update every 10 meters to conserve battery
        self.authorizationStatus = locationManager.authorizationStatus
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
    
    // MARK: - Location Updates Lifecycle
    
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
            AppLogger.location.info("Started offline GPS location updates.")
        } else {
            requestLocationPermission()
        }
    }
    
    func stopSharingLocation() {
        guard isSharingLocation else { return }
        self.isSharingLocation = false
        locationManager.stopUpdatingLocation()
        AppLogger.location.info("Stopped location updates.")
    }
    
    /// One-shot offline GPS coordinate snapshot for immediate location sharing
    func getCurrentLocationSnapshot(completion: @escaping (CLLocation?) -> Void) {
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
    
    // MARK: - Distance & Bearing Calculation Helpers
    
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
    
    private func bearingToCompassDirection(_ degrees: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees + 22.5).truncatingRemainder(dividingBy: 360.0) / 45.0)
        return directions[max(0, min(index, directions.count - 1))]
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            AppLogger.location.info("Location authorization changed: \(manager.authorizationStatus.rawValue)")
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                if self.isSharingLocation {
                    manager.startUpdatingLocation()
                }
            } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                self.isSharingLocation = false
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.currentCoordinate = location.coordinate
            self.currentAltitude = location.altitude
            self.currentAccuracy = location.horizontalAccuracy
            self.lastLocationTimestamp = location.timestamp
            
            if let completion = self.oneShotCompletion {
                completion(location)
                self.oneShotCompletion = nil
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        AppLogger.location.error("Location manager didFailWithError: \(error.localizedDescription)")
        if let completion = self.oneShotCompletion {
            completion(locationManager.location)
            self.oneShotCompletion = nil
        }
    }
}
