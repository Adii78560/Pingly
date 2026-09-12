//
//  BreadcrumbViewModel.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import Foundation
import CoreLocation
import Combine
import SwiftUI

/// ViewModel driving breadcrumb tracking UI, statistics, and Return-to-Start backtracking
@MainActor
final class BreadcrumbViewModel: ObservableObject {
    
    // MARK: - Published State
    @Published var isTracking: Bool = false
    @Published var activeTrack: SDBreadcrumbTrack?
    @Published var recordedPoints: [SDBreadcrumbPoint] = []
    @Published var allTracks: [SDBreadcrumbTrack] = []
    @Published var totalDistanceMeters: Double = 0.0
    @Published var durationSeconds: TimeInterval = 0.0
    @Published var selectedTrack: SDBreadcrumbTrack?
    @Published var selectedTrackPoints: [SDBreadcrumbPoint] = []
    
    private let trackingService = BreadcrumbTrackingService.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupSubscriptions()
        loadTracks()
    }
    
    private func setupSubscriptions() {
        trackingService.$isTracking
            .receive(on: DispatchQueue.main)
            .assign(to: \.isTracking, on: self)
            .store(in: &cancellables)
        
        trackingService.$activeTrack
            .receive(on: DispatchQueue.main)
            .assign(to: \.activeTrack, on: self)
            .store(in: &cancellables)
        
        trackingService.$recordedPoints
            .receive(on: DispatchQueue.main)
            .assign(to: \.recordedPoints, on: self)
            .store(in: &cancellables)
        
        trackingService.$totalDistanceMeters
            .receive(on: DispatchQueue.main)
            .assign(to: \.totalDistanceMeters, on: self)
            .store(in: &cancellables)
        
        trackingService.$activeTrackDuration
            .receive(on: DispatchQueue.main)
            .assign(to: \.durationSeconds, on: self)
            .store(in: &cancellables)
    }
    
    func loadTracks() {
        self.allTracks = trackingService.fetchAllTracks()
    }
    
    func startTracking() {
        trackingService.startTracking()
        loadTracks()
    }
    
    func stopTracking() {
        trackingService.stopTracking()
        loadTracks()
    }
    
    func selectTrack(_ track: SDBreadcrumbTrack) {
        self.selectedTrack = track
        self.selectedTrackPoints = trackingService.fetchPoints(for: track.id)
    }
    
    func deleteTrack(_ track: SDBreadcrumbTrack) {
        trackingService.deleteTrack(track)
        loadTracks()
        if selectedTrack?.id == track.id {
            selectedTrack = nil
            selectedTrackPoints = []
        }
    }
    
    func returnToStartTarget() -> NavigationTarget? {
        return trackingService.createReturnToStartTarget()
    }
    
    var formattedDuration: String {
        let totalSeconds = Int(durationSeconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    var formattedDistance: String {
        if totalDistanceMeters < 1000 {
            return String(format: "%.0f m", totalDistanceMeters)
        } else {
            return String(format: "%.2f km", totalDistanceMeters / 1000.0)
        }
    }
}
