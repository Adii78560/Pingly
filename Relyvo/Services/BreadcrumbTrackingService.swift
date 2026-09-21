//
//  BreadcrumbTrackingService.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import Foundation
import CoreLocation
import Combine
import SwiftData
import os

/// GPS Breadcrumb Trail Recording and "Return-to-Start" Backtracking Engine
@MainActor
final class BreadcrumbTrackingService: ObservableObject {
    
    static let shared = BreadcrumbTrackingService()
    
    // MARK: - Published State
    @Published private(set) var activeTrack: SDBreadcrumbTrack?
    @Published private(set) var recordedPoints: [SDBreadcrumbPoint] = []
    @Published private(set) var isTracking: Bool = false
    @Published private(set) var totalDistanceMeters: Double = 0.0
    @Published private(set) var activeTrackDuration: TimeInterval = 0.0
    
    private var lastRecordedPoint: CLLocation?
    private var lastRecordedHeading: Double?
    private var lastRecordedTimestamp: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()
    private var durationTimer: Timer?
    
    private init() {
        restoreActiveTrack()
        setupLocationObserver()
    }
    
    // MARK: - Persistence Restoration
    
    /// Restores any previously active track that survived an app restart
    private func restoreActiveTrack() {
        let tracks = fetchAllTracks()
        if let active = tracks.first(where: { $0.isActive }) {
            self.activeTrack = active
            self.isTracking = true
            self.totalDistanceMeters = active.totalDistanceMeters
            self.recordedPoints = fetchPoints(for: active.id)
            startDurationTimer()
        }
    }
    
    private func setupLocationObserver() {
        Publishers.CombineLatest(
            LocationService.shared.$currentCoordinate,
            LocationService.shared.$smoothedHeading
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] coord, heading in
            guard let self = self, self.isTracking, let coord = coord else { return }
            self.evaluateLocationSample(coord: coord, heading: heading)
        }
        .store(in: &cancellables)
    }
    
    // MARK: - Public Tracking Controls
    
    /// Start a new breadcrumb recording session
    func startTracking(name: String? = nil) {
        // Stop any previous active track
        if isTracking {
            stopTracking()
        }
        
        let trackName = name ?? "Track \(Date().formatted(date: .abbreviated, time: .shortened))"
        let currentLoc = LocationService.shared.currentCoordinate
        let currentAlt = LocationService.shared.currentAltitude
        
        let newTrack = SDBreadcrumbTrack(
            name: trackName,
            startedAt: Date(),
            isActive: true,
            totalDistanceMeters: 0.0,
            pointsCount: 0,
            startLatitude: currentLoc?.latitude,
            startLongitude: currentLoc?.longitude,
            startAltitude: currentAlt
        )
        
        let context = SwiftDataService.shared.context
        context.insert(newTrack)
        do {
            try context.save()
        } catch {
        }
        
        self.activeTrack = newTrack
        self.recordedPoints = []
        self.totalDistanceMeters = 0.0
        self.isTracking = true
        self.lastRecordedPoint = nil
        self.lastRecordedHeading = nil
        self.lastRecordedTimestamp = .distantPast
        
        LocationService.shared.startSharingLocation()
        LocationService.shared.startUpdatingHeading()
        startDurationTimer()
        
        // Record initial origin point immediately if GPS is available
        if let currentLoc = currentLoc {
            evaluateLocationSample(coord: currentLoc, heading: LocationService.shared.smoothedHeading, forceRecord: true)
        }
        
    }
    
    /// Stop and finalize current breadcrumb recording session
    func stopTracking() {
        guard let track = activeTrack else { return }
        
        track.isActive = false
        track.endedAt = Date()
        track.totalDistanceMeters = self.totalDistanceMeters
        track.pointsCount = self.recordedPoints.count
        
        let context = SwiftDataService.shared.context
        do {
            try context.save()
        } catch {
        }
        
        self.activeTrack = nil
        self.isTracking = false
        stopDurationTimer()
        
    }
    
    /// Delete a recorded track and its points
    func deleteTrack(_ track: SDBreadcrumbTrack) {
        let context = SwiftDataService.shared.context
        let points = fetchPoints(for: track.id)
        for p in points {
            context.delete(p)
        }
        context.delete(track)
        
        if activeTrack?.id == track.id {
            self.activeTrack = nil
            self.isTracking = false
            self.recordedPoints = []
            stopDurationTimer()
        }
        
        do {
            try context.save()
        } catch {
        }
    }
    
    // MARK: - Smart Filtering Engine
    
    /// Evaluate whether a location update qualifies to be saved as a persistent breadcrumb point
    private func evaluateLocationSample(coord: CLLocationCoordinate2D, heading: Double, forceRecord: Bool = false) {
        let accuracy = LocationService.shared.currentAccuracy ?? 10.0
        guard accuracy > 0 && accuracy <= 50.0 else { return } // Reject low-precision GPS jitter
        
        let currentLocation = CLLocation(
            coordinate: coord,
            altitude: LocationService.shared.currentAltitude ?? 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 10,
            course: LocationService.shared.currentCourse ?? -1,
            speed: LocationService.shared.currentSpeed ?? -1,
            timestamp: Date()
        )
        
        let now = Date()
        
        if forceRecord || lastRecordedPoint == nil {
            recordPoint(currentLocation: currentLocation, heading: heading, sequenceIndex: recordedPoints.count)
            return
        }
        
        guard let lastPoint = lastRecordedPoint else { return }
        
        let distanceMoved = currentLocation.distance(from: lastPoint)
        
        // Apply 3-meter deadband filter to prevent stationary GPS drift
        guard distanceMoved >= 3.0 else { return }
        
        let timeElapsed = now.timeIntervalSince(lastRecordedTimestamp)
        
        var shouldRecord = false
        
        // 1. Distance threshold: moved >= 10 meters
        if distanceMoved >= 10.0 {
            shouldRecord = true
        }
        // 2. Heading delta threshold: turned >= 15 degrees while moving
        else if let lastHeading = lastRecordedHeading, (currentLocation.speed > 0.5 || distanceMoved >= 3.0) {
            let headingDelta = abs(CircularAngleHelper.shortestAngularDifference(from: lastHeading, to: heading))
            if headingDelta >= 15.0 {
                shouldRecord = true
            }
        }
        // 3. Time threshold: elapsed >= 30 seconds (if moved at least 3m to avoid noise while stationary)
        else if timeElapsed >= 30.0 && distanceMoved >= 3.0 {
            shouldRecord = true
        }
        
        if shouldRecord {
            recordPoint(currentLocation: currentLocation, heading: heading, sequenceIndex: recordedPoints.count)
            self.totalDistanceMeters += distanceMoved
            self.activeTrack?.totalDistanceMeters = self.totalDistanceMeters
            self.activeTrack?.pointsCount = self.recordedPoints.count
        }
    }
    
    private func recordPoint(currentLocation: CLLocation, heading: Double, sequenceIndex: Int) {
        guard let track = activeTrack else { return }
        
        let point = SDBreadcrumbPoint(
            trackID: track.id,
            latitude: currentLocation.coordinate.latitude,
            longitude: currentLocation.coordinate.longitude,
            altitude: currentLocation.altitude,
            accuracy: currentLocation.horizontalAccuracy,
            speed: currentLocation.speed >= 0 ? currentLocation.speed : nil,
            course: currentLocation.course >= 0 ? currentLocation.course : nil,
            heading: heading,
            timestamp: Date(),
            sequenceIndex: sequenceIndex
        )
        
        let context = SwiftDataService.shared.context
        context.insert(point)
        self.recordedPoints.append(point)
        
        // Cap track buffer at 500 entries (FIFO)
        if self.recordedPoints.count > 500 {
            let oldest = self.recordedPoints.removeFirst()
            context.delete(oldest)
        }
        
        do {
            try context.save()
        } catch {
        }
        
        self.lastRecordedPoint = currentLocation
        self.lastRecordedHeading = heading
        self.lastRecordedTimestamp = Date()
        
    }
    
    // MARK: - "Return to Start" Backtracking Target Generator
    
    /// Generates a NavigationTarget representing the origin point of the active or latest track
    func createReturnToStartTarget() -> NavigationTarget? {
        if let active = activeTrack, let startLat = active.startLatitude, let startLon = active.startLongitude {
            return NavigationTarget(
                id: "return_to_start_\(active.id.uuidString)",
                displayName: "Origin: \(active.name)",
                coordinate: CLLocationCoordinate2D(latitude: startLat, longitude: startLon),
                altitude: active.startAltitude,
                accuracy: 5.0,
                timestamp: active.startedAt,
                sequenceNumber: 0,
                targetType: .returnToStart
            )
        }
        
        // If no active track, check the latest completed track
        let tracks = fetchAllTracks()
        if let latest = tracks.first, let startLat = latest.startLatitude, let startLon = latest.startLongitude {
            return NavigationTarget(
                id: "return_to_start_\(latest.id.uuidString)",
                displayName: "Origin: \(latest.name)",
                coordinate: CLLocationCoordinate2D(latitude: startLat, longitude: startLon),
                altitude: latest.startAltitude,
                accuracy: 5.0,
                timestamp: latest.startedAt,
                sequenceNumber: 0,
                targetType: .returnToStart
            )
        }
        
        return nil
    }
    
    // MARK: - SwiftData Queries
    
    func fetchAllTracks() -> [SDBreadcrumbTrack] {
        let descriptor = FetchDescriptor<SDBreadcrumbTrack>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let context = SwiftDataService.shared.context
        return (try? context.fetch(descriptor)) ?? []
    }
    
    func fetchPoints(for trackID: UUID) -> [SDBreadcrumbPoint] {
        let descriptor = FetchDescriptor<SDBreadcrumbPoint>(
            predicate: #Predicate { $0.trackID == trackID },
            sortBy: [SortDescriptor(\.sequenceIndex, order: .forward)]
        )
        let context = SwiftDataService.shared.context
        return (try? context.fetch(descriptor)) ?? []
    }
    
    // MARK: - Duration Timer
    
    private func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let active = self.activeTrack else { return }
            self.activeTrackDuration = Date().timeIntervalSince(active.startedAt)
        }
    }
    
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}
