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
    case roadRoute
}

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
    @Published var navigationMode: NavigationMode = .directTarget
    
    @Published var showTechnicalDetails: Bool = false
    @Published var showLayerSettings: Bool = false
    
    // Target Navigation State
    @Published var target: NavigationTarget?
    @Published var vector: RelativeNavigationVector?
    
    // Road Navigation State
    @Published var activeRoute: Route?
    @Published var routeProgress: RouteProgress?
    @Published var routeState: RouteProgressState = .onRoute
    @Published var voiceGuidanceEnabled: Bool = true
    @Published var isRerouting: Bool = false
    
    // Common State
    @Published var userHeading: Double = 0.0
    @Published var continuousHeading: Double = 0.0
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var isNavigating: Bool = false
    @Published var isHapticsEnabled: Bool = true
    @Published var isRoutingCalculationActive: Bool = false
    
    private let navService = OfflineNavigationService.shared
    private let locationService = LocationService.shared
    private let hapticManager = CompassHapticManager.shared
    private var voiceGuidanceService: VoiceGuidanceService?
    
    private var routingDatabase: RoutingDatabase?
    private var routingService: OfflineRoutingService?
    private var routeProgressService: RouteProgressService?
    
    private var cancellables = Set<AnyCancellable>()
    private var routingTask: Task<Void, Never>?
    
    init(initialTarget: NavigationTarget? = nil) {
        // Initialize routing engine
        // Assuming monaco for prototype, in real app it would come from OfflineMapService
        // Use the exact path that is present in the workspace
        let dbPath = "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite"
        if FileManager.default.fileExists(atPath: dbPath) {
            let db = RoutingDatabase(fileURL: URL(fileURLWithPath: dbPath))
            self.routingDatabase = db
            let rService = OfflineRoutingService(database: db)
            self.routingService = rService
            self.routeProgressService = RouteProgressService(database: db, routingService: rService)
        } else {
            AppLogger.location.error("[NavigationViewModel] DB not found at \(dbPath)")
        }
        
        self.voiceGuidanceService = VoiceGuidanceService()
        
        setupSubscriptions()
        
        if let initialTarget = initialTarget {
            setTarget(initialTarget)
        }
    }
    
    private func setupSubscriptions() {
        // Observe target & vector updates
        navService.$activeTarget
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                guard let self = self else { return }
                if self.navigationMode == .directTarget {
                    self.target = t
                }
            }
            .store(in: &cancellables)
        
        navService.$currentVector
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in
                guard let self = self else { return }
                if self.navigationMode == .directTarget {
                    self.vector = v
                }
            }
            .store(in: &cancellables)
        
        navService.$isNavigating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] navigating in
                // Only update isNavigating if we are in directTarget mode
                if self?.navigationMode == .directTarget {
                    self?.isNavigating = navigating
                }
            }
            .store(in: &cancellables)
        
        // Observe location & headings
        locationService.$currentCoordinate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coord in
                guard let self = self else { return }
                self.currentCoordinate = coord
                if self.navigationMode == .roadRoute, let coord = coord {
                    self.updateRouteProgress(location: CLLocation(latitude: coord.latitude, longitude: coord.longitude), heading: self.continuousHeading)
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
        
        if target.targetType == .peer || target.targetType == .waypoint || target.targetType == .sos {
            attemptRoadRouting(to: target)
        } else {
            // Fallback for Return to Start
            activateDirectNavigation(target: target)
        }
    }
    
    func stopNavigation() {
        routingTask?.cancel()
        routingTask = nil
        
        if navigationMode == .directTarget {
            navService.stopNavigating()
        } else {
            isNavigating = false
            activeRoute = nil
            routeProgress = nil
            routeState = .onRoute
            voiceGuidanceService?.stop()
        }
    }
    
    func toggleHaptics() {
        hapticManager.enableCompassHaptics.toggle()
    }
    
    func toggleVoice() {
        voiceGuidanceEnabled.toggle()
    }
    
    func returnToStart() {
        if let returnTarget = BreadcrumbTrackingService.shared.createReturnToStartTarget() {
            setTarget(returnTarget)
            displayMode = .compass
        }
    }
    
    // MARK: - Routing Logic
    
    private func attemptRoadRouting(to target: NavigationTarget) {
        guard let rService = routingService, let progressService = routeProgressService, let origin = locationService.currentCoordinate else {
            activateDirectNavigation(target: target)
            return
        }
        
        isRoutingCalculationActive = true
        routingTask?.cancel()
        routingTask = Task {
            do {
                let route = try await rService.calculateRoute(from: origin, to: target.coordinate)
                
                if Task.isCancelled { return }
                
                await progressService.setRoute(route)
                
                await MainActor.run {
                    self.navigationMode = .roadRoute
                    self.activeRoute = route
                    self.routeProgress = nil
                    self.routeState = .onRoute
                    self.isNavigating = true
                    self.isRoutingCalculationActive = false
                    
                    self.navService.stopNavigating() // Stop direct mode overlapping
                    self.locationService.startSharingLocation()
                    
                    AppLogger.location.info("[NavigationViewModel] Road routing activated for \(target.displayName)")
                }
            } catch {
                if Task.isCancelled { return }
                
                await MainActor.run {
                    self.isRoutingCalculationActive = false
                    AppLogger.location.warning("[NavigationViewModel] Routing failed: \(error.localizedDescription). Falling back to Direct Target.")
                    self.activateDirectNavigation(target: target)
                }
            }
        }
    }
    
    private func activateDirectNavigation(target: NavigationTarget) {
        self.navigationMode = .directTarget
        self.activeRoute = nil
        self.routeProgress = nil
        self.isNavigating = true
        navService.startNavigating(to: target)
        AppLogger.location.info("[NavigationViewModel] Direct Target Navigation activated for \(target.displayName)")
    }
    
    // MARK: - Progress Updates
    
    private func updateRouteProgress(location: CLLocation, heading: Double) {
        guard let progressService = routeProgressService else { return }
        
        Task {
            if let progress = try? await progressService.updateProgress(location: location, heading: heading) {
                let state = await progressService.stateMachine
                
                await MainActor.run {
                    self.routeProgress = progress
                    self.routeState = state
                    self.isRerouting = (state == .rerouting)
                    
                    if state == .newRoute {
                        self.activeRoute = progress.route
                    }
                    
                    // Voice & Haptics
                    if let maneuver = progress.nextManeuver, !self.isRerouting {
                        if self.voiceGuidanceEnabled {
                            self.voiceGuidanceService?.announceManeuver(maneuver)
                        }
                        if self.isHapticsEnabled {
                            self.hapticManager.evaluateDirectionalHaptic(
                                relativeBearing: maneuver.turnAngle,
                                distanceMeters: maneuver.distanceFromCurrentPosition,
                                isArrived: progress.isArrived
                            )
                        }
                    }
                    
                    if state == .rerouting {
                        if self.voiceGuidanceEnabled {
                            self.voiceGuidanceService?.announceRerouting()
                        }
                    }
                }
            }
        }
    }
}
