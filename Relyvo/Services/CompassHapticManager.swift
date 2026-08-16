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
public enum ProximityBand: String {
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

/// Central Haptic Feedback Manager for the Relative Location Compass
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
    private var isTargetAligned: Bool = false
    
    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let lock = NSLock()
    
    private init() {
        lightImpactGenerator.prepare()
        mediumImpactGenerator.prepare()
    }
    
    /// Evaluates current relative bearing and distance metrics to trigger subtle haptics on state transitions
    public func evaluateCompassState(relativeBearing: Double, distanceMeters: Double) {
        guard enableCompassHaptics else { return }
        
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        guard now.timeIntervalSince(lastHapticTimestamp) >= minCooldownSeconds else { return }
        
        // 1. Proximity Band Transition Check
        let newBand = ProximityBand.band(for: distanceMeters)
        if newBand != currentProximityBand {
            currentProximityBand = newBand
            lastHapticTimestamp = now
            triggerHaptic(style: newBand == .arrived ? .medium : .light)
            AppLogger.location.info("[CompassHaptic] Event PROXIMITY_BAND_CHANGE -> \(newBand.rawValue), distance=\(distanceMeters)m")
            return
        }
        
        // 2. Alignment Window Check (Target directly ahead <= 10.0°)
        let normalizedRelAngle = abs(CircularAngleHelper.shortestAngularDifference(from: 0.0, to: relativeBearing))
        let newlyAligned = normalizedRelAngle <= 10.0
        
        if newlyAligned && !isTargetAligned {
            isTargetAligned = true
            lastHapticTimestamp = now
            triggerHaptic(style: .light)
            AppLogger.location.info("[CompassHaptic] Event ALIGNMENT_ENTER, relativeBearing=\(relativeBearing)°, distance=\(distanceMeters)m")
        } else if !newlyAligned && isTargetAligned {
            isTargetAligned = false
        }
    }
    
    private func triggerHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        DispatchQueue.main.async {
            switch style {
            case .light:
                self.lightImpactGenerator.impactOccurred()
            case .medium:
                self.mediumImpactGenerator.impactOccurred()
            default:
                self.lightImpactGenerator.impactOccurred()
            }
        }
    }
}
