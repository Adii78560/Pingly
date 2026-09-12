//
//  TacticalMapViewModel.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import Foundation
import CoreLocation
import Combine
import SwiftUI

/// ViewModel managing state, layers, camera viewports, and overlays on the Tactical Map
@MainActor
final class TacticalMapViewModel: ObservableObject {
    
    // MARK: - Viewport & Camera State
    @Published var centerCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 30.9010, longitude: 75.8573)
    @Published var zoomLevel: Double = 14.0 // 2...18
    @Published var isFollowingUser: Bool = true
    @Published var isNorthUp: Bool = true
    
    // MARK: - Layer Toggles
    @Published var showUserLayer: Bool = true
    @Published var showTargetLayer: Bool = true
    @Published var showPeersLayer: Bool = true
    @Published var showSOSLayer: Bool = true
    @Published var showBreadcrumbsLayer: Bool = true
    @Published var showGridLayer: Bool = true
    @Published var showTopoContours: Bool = true
    
    // MARK: - Active Nodes
    @Published var userCoordinate: CLLocationCoordinate2D?
    @Published var userHeading: Double = 0.0
    @Published var userAccuracy: Double = 10.0
    @Published var activeTarget: NavigationTarget?
    @Published var meshPeers: [PeerDevice] = []
    @Published var selectedPeer: PeerDevice?
    
    private let locationService = LocationService.shared
    private let multipeerService = MultipeerService.shared
    private let navService = OfflineNavigationService.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupSubscriptions()
    }
    
    private func setupSubscriptions() {
        // Observe User Location
        locationService.$currentCoordinate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coord in
                guard let self = self, let coord = coord else { return }
                self.userCoordinate = coord
                if self.isFollowingUser {
                    self.centerCoordinate = coord
                }
            }
            .store(in: &cancellables)
        
        locationService.$currentHeading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] heading in
                if let heading = heading {
                    self?.userHeading = heading
                }
            }
            .store(in: &cancellables)
        
        locationService.$currentAccuracy
            .receive(on: DispatchQueue.main)
            .sink { [weak self] acc in
                if let acc = acc {
                    self?.userAccuracy = acc
                }
            }
            .store(in: &cancellables)
        
        // Observe Active Target
        navService.$activeTarget
            .receive(on: DispatchQueue.main)
            .assign(to: \.activeTarget, on: self)
            .store(in: &cancellables)
        
        // Observe Mesh Peers
        multipeerService.$connectedPeers
            .receive(on: DispatchQueue.main)
            .assign(to: \.meshPeers, on: self)
            .store(in: &cancellables)
    }
    
    // MARK: - Camera Controls
    
    func centerOnUser() {
        if let userCoord = userCoordinate {
            self.centerCoordinate = userCoord
            self.isFollowingUser = true
        }
    }
    
    func centerOnTarget() {
        if let targetCoord = activeTarget?.coordinate {
            self.centerCoordinate = targetCoord
            self.isFollowingUser = false
        }
    }
    
    func zoomIn() {
        zoomLevel = min(18.0, zoomLevel + 1.0)
    }
    
    func zoomOut() {
        zoomLevel = max(2.0, zoomLevel - 1.0)
    }
    
    func pan(dx: Double, dy: Double, viewSize: CGSize) {
        isFollowingUser = false
        let deltaM = 1.0 / (pow(2.0, zoomLevel) * 256.0)
        let lonDelta = dx * deltaM * 360.0
        let latDelta = -dy * deltaM * 180.0
        
        let newLat = max(-85.0, min(85.0, centerCoordinate.latitude + latDelta))
        let newLon = max(-180.0, min(180.0, centerCoordinate.longitude + lonDelta))
        centerCoordinate = CLLocationCoordinate2D(latitude: newLat, longitude: newLon)
    }
}
