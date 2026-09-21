//
//  NavigationViewModel.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import Foundation
import CoreLocation
import Combine
import SwiftUI
import os

/// Core Navigation Method (Direct vs Road)
enum NavigationMode: String, Sendable, Equatable {
    case directTarget
}

/// Mode selector for the offline navigation experience
enum NavigationDisplayMode: String, CaseIterable, Sendable {
    case compass = "COMPASS RADAR"
    
    var iconName: String {
        switch self {
        case .compass: return "location.north.line.fill"
        }
    }
}

/// ViewModel powering the full-screen Offline Navigation HUD
@MainActor
final class NavigationViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var displayMode: NavigationDisplayMode = .compass
    @Published var navigationMode: NavigationMode = .directTarget
    
    @Published var showTechnicalDetails: Bool = false
    @Published var showLayerSettings: Bool = false
    
    // Target Navigation State
    @Published var target: NavigationTarget?
    @Published var vector: RelativeNavigationVector?
    
    // Common State
    @Published var userHeading: Double = 0.0
    @Published var smoothedHeading: Double = 0.0
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var isNavigating: Bool = false
    @Published var isHapticsEnabled: Bool = true
    
    private let navService = OfflineNavigationService.shared
    private let locationService = LocationService.shared
    private let hapticManager = CompassHapticManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    init(initialTarget: NavigationTarget? = nil) {
        setupSubscriptions()
        
        if let initialTarget = initialTarget {
            setTarget(initialTarget)
        }
    }
    
    private func setupSubscriptions() {
        // Observe target & vector updates
        navService.$activeTarget
            .receive(on: DispatchQueue.main)
            .assign(to: \.target, on: self)
            .store(in: &cancellables)
        
        navService.$currentVector
            .receive(on: DispatchQueue.main)
            .assign(to: \.vector, on: self)
            .store(in: &cancellables)
        
        navService.$isNavigating
            .receive(on: DispatchQueue.main)
            .assign(to: \.isNavigating, on: self)
            .store(in: &cancellables)
        
        // Observe location & headings
        locationService.$currentCoordinate
            .receive(on: DispatchQueue.main)
            .assign(to: \.currentCoordinate, on: self)
            .store(in: &cancellables)
            
        locationService.$currentHeading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] heading in
                if let heading = heading {
                    self?.userHeading = heading
                }
            }
            .store(in: &cancellables)
        
        locationService.$smoothedHeading
            .receive(on: DispatchQueue.main)
            .assign(to: \.smoothedHeading, on: self)
            .store(in: &cancellables)
        
        // Observe haptic preference
        hapticManager.$enableCompassHaptics
            .receive(on: DispatchQueue.main)
            .assign(to: \.isHapticsEnabled, on: self)
            .store(in: &cancellables)
    }
    
    // MARK: - Public User Actions
    
    func setTarget(_ target: NavigationTarget) {
        self.target = target
        activateDirectNavigation(target: target)
    }
    
    func stopNavigation() {
        navService.stopNavigating()
    }
    
    func toggleHaptics() {
        hapticManager.enableCompassHaptics.toggle()
    }
    
    func returnToStart() {
        if let returnTarget = BreadcrumbTrackingService.shared.createReturnToStartTarget() {
            setTarget(returnTarget)
            displayMode = .compass
        }
    }
    
    // MARK: - Navigation Activation
    
    private func activateDirectNavigation(target: NavigationTarget) {
        self.navigationMode = .directTarget
        self.isNavigating = true
        navService.startNavigating(to: target)
    }
}
