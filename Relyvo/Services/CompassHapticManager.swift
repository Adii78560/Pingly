//
//  CompassHapticManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 14/08/26.
//

import Foundation
import UIKit
import SwiftUI
import Combine
import os

/// Proximity distance band categories for directional haptic feedback
public enum ProximityBand: String, Sendable {
    case far = "FAR"              // > 100m
    case approaching = "APPROACHING" // 50m - 100m
    case close = "CLOSE"          // 10m - 50m
    case arrived = "ARRIVED"      // < 10m
    
    public static func band(for distanceMeters: Double) -> ProximityBand {
        if distanceMeters < 10.0 {
            return .arrived
        } else if distanceMeters <= 50.0 {
            return .close
        } else if distanceMeters <= 100.0 {
            return .approaching
        } else {
            return .far
        }
    }
}

/// Directional orientation states for navigation feedback
public enum DirectionalHapticState: String, Sendable {
    case targetBehind = "TARGET_BEHIND"
    case targetLeft = "TARGET_LEFT"
    case targetSlightLeft = "TARGET_SLIGHT_LEFT"
    case targetCenter = "TARGET_CENTER"
    case targetSlightRight = "TARGET_SLIGHT_RIGHT"
    case targetRight = "TARGET_RIGHT"
    case arrived = "ARRIVED"
    
    public static func state(for relativeBearing: Double, isArrived: Bool) -> DirectionalHapticState {
        if isArrived {
            return .arrived
        }
        let angle = CircularAngleHelper.shortestAngularDifference(from: 0.0, to: relativeBearing)
        let absAngle = abs(angle)
        
        if absAngle <= 10.0 {
            return .targetCenter
        } else if absAngle > 135.0 {
            return .targetBehind
        } else if angle > 0 {
            return absAngle <= 45.0 ? .targetSlightRight : .targetRight
        } else {
            return absAngle <= 45.0 ? .targetSlightLeft : .targetLeft
        }
    }
}

/// Central Haptic Feedback Manager for the Relative Location & Offline Navigation Engine
public final class CompassHapticManager: ObservableObject {
    
    public static let shared = CompassHapticManager()
    
    @Published public var enableCompassHaptics: Bool = UserDefaults.standard.object(forKey: "pref_compass_haptics") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enableCompassHaptics, forKey: "pref_compass_haptics")
        }
    }
    
    private var lastHapticTimestamp: Date = .distantPast
    private let minCooldownSeconds: TimeInterval = 0.8
    
    private var currentProximityBand: ProximityBand = .far
    private var currentDirectionalState: DirectionalHapticState = .targetCenter
    private var isTargetAligned: Bool = false
    
    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpactGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let lock = NSLock()
    
    private init() {
        lightImpactGenerator.prepare()
        mediumImpactGenerator.prepare()
        heavyImpactGenerator.prepare()
        notificationGenerator.prepare()
    }
    
    /// Reset cached states when navigating to a new target or stopping navigation
    public func resetState() {
        lock.lock()
        defer { lock.unlock() }
        currentProximityBand = .far
        currentDirectionalState = .targetCenter
        isTargetAligned = false
        lastHapticTimestamp = .distantPast
    }
    
    /// Evaluates current directional navigation state and triggers throttled, non-spammy haptic cues
    public func evaluateDirectionalHaptic(relativeBearing: Double, distanceMeters: Double, isArrived: Bool) {
        guard enableCompassHaptics else { return }
        
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        guard now.timeIntervalSince(lastHapticTimestamp) >= minCooldownSeconds else { return }
        
        // 1. Arrival Check
        if isArrived {
            if currentDirectionalState != .arrived {
                currentDirectionalState = .arrived
                lastHapticTimestamp = now
                triggerNotification(type: .success)
                AppLogger.location.info("[CompassHaptic] Event ARRIVED at target")
            }
            return
        }
        
        // 2. Proximity Band Transition Check
        let newBand = ProximityBand.band(for: distanceMeters)
        if newBand != currentProximityBand {
            currentProximityBand = newBand
            lastHapticTimestamp = now
            triggerHaptic(style: newBand == .close ? .medium : .light)
            AppLogger.location.info("[CompassHaptic] Event PROXIMITY_BAND_CHANGE -> \(newBand.rawValue), distance=\(distanceMeters)m")
            return
        }
        
        // 3. Directional State Transition Check
        let newState = DirectionalHapticState.state(for: relativeBearing, isArrived: isArrived)
        if newState != currentDirectionalState {
            let previousState = currentDirectionalState
            currentDirectionalState = newState
            
            // Only trigger haptics when entering Center (aligned) or changing major orientation sectors
            if newState == .targetCenter {
                lastHapticTimestamp = now
                triggerHaptic(style: .medium)
                AppLogger.location.info("[CompassHaptic] Event ALIGNED (TARGET_CENTER), rel=\(relativeBearing)°")
            } else if (previousState == .targetLeft && newState == .targetRight) || (previousState == .targetRight && newState == .targetLeft) {
                lastHapticTimestamp = now
                triggerHaptic(style: .light)
            } else if newState == .targetBehind && previousState != .targetBehind {
                lastHapticTimestamp = now
                triggerHaptic(style: .light)
            }
        }
    }
    
    /// Legacy compatibility evaluator for RelativeLocationView
    public func evaluateCompassState(relativeBearing: Double, distanceMeters: Double) {
        evaluateDirectionalHaptic(
            relativeBearing: relativeBearing,
            distanceMeters: distanceMeters,
            isArrived: distanceMeters < 10.0
        )
    }
    
    private func triggerHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        DispatchQueue.main.async {
            switch style {
            case .light:
                self.lightImpactGenerator.impactOccurred()
            case .medium:
                self.mediumImpactGenerator.impactOccurred()
            case .heavy:
                self.heavyImpactGenerator.impactOccurred()
            @unknown default:
                self.lightImpactGenerator.impactOccurred()
            }
        }
    }
    
    private func triggerNotification(type: UINotificationFeedbackGenerator.FeedbackType) {
        DispatchQueue.main.async {
            self.notificationGenerator.notificationOccurred(type)
        }
    }
}
