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

/// Mode selector for the offline navigation experience
enum NavigationDisplayMode: String, CaseIterable, Sendable {
    case compass = "COMPASS RADAR"
    case tacticalMap = "TACTICAL MAP"
    
    var iconName: String {
        switch self {
        case .compass: return "location.north.line.fill"
        case .tacticalMap: return "map.fill"
        }
    }
}

/// ViewModel powering the full-screen Offline Navigation HUD
@MainActor
final class NavigationViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var displayMode: NavigationDisplayMode = .compass
    @Published var showTechnicalDetails: Bool = false
    @Published var showLayerSettings: Bool = false
    @Published var target: NavigationTarget?
    @Published var vector: RelativeNavigationVector?
    @Published var userHeading: Double = 0.0
    @Published var continuousHeading: Double = 0.0
    @Published var isNavigating: Bool = false
    @Published var isHapticsEnabled: Bool = true
    
    private let navService = OfflineNavigationService.shared
    private let locationService = LocationService.shared
    private let hapticManager = CompassHapticManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    init(initialTarget: NavigationTarget? = nil) {
        if let initialTarget = initialTarget {
            self.target = initialTarget
            navService.startNavigating(to: initialTarget)
        }
        
        setupSubscriptions()
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
        
        // Observe compass headings
        locationService.$currentHeading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] heading in
                if let heading = heading {
                    self?.userHeading = heading
                }
            }
            .store(in: &cancellables)
        
        locationService.$continuousHeading
            .receive(on: DispatchQueue.main)
            .assign(to: \.continuousHeading, on: self)
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
        navService.startNavigating(to: target)
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
}
