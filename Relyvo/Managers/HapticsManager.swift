//
//  HapticsManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 13/08/26.
//

import UIKit

/// Advanced Tactical Haptics Manager providing CoreHaptics & UIKit feedback patterns
final class HapticsManager {
    static let shared = HapticsManager()
    
    private init() {}
    
    // MARK: - Impact Feedback Generators
    
    func lightImpact() {
        #if !targetEnvironment(simulator)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
    
    func mediumImpact() {
        #if !targetEnvironment(simulator)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
    
    func heavyImpact() {
        #if !targetEnvironment(simulator)
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
    
    func rigidImpact() {
        #if !targetEnvironment(simulator)
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
    
    func softImpact() {
        #if !targetEnvironment(simulator)
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
    
    // MARK: - Selection Feedback
    
    func selectionFeedback() {
        #if !targetEnvironment(simulator)
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
        #endif
    }
    
    // MARK: - Notification Feedback
    
    func successFeedback() {
        #if !targetEnvironment(simulator)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        #endif
    }
    
    func warningFeedback() {
        #if !targetEnvironment(simulator)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
        #endif
    }
    
    func errorFeedback() {
        #if !targetEnvironment(simulator)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
        #endif
    }
    
    // MARK: - Tactical Heartbeat Pulse Pattern (Lub-Dub)
    
    /// Triggers a double-pulse heartbeat pattern (light tap followed by medium tap)
    func heartbeatPulse() {
        #if !targetEnvironment(simulator)
        let generator1 = UIImpactFeedbackGenerator(style: .light)
        generator1.prepare()
        generator1.impactOccurred()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let generator2 = UIImpactFeedbackGenerator(style: .medium)
            generator2.prepare()
            generator2.impactOccurred()
        }
        #endif
    }
}

// MARK: - Backward Compatibility Alias
enum HapticManager {
    static func lightImpact() { HapticsManager.shared.lightImpact() }
    static func mediumImpact() { HapticsManager.shared.mediumImpact() }
    static func heavyImpact() { HapticsManager.shared.heavyImpact() }
    static func rigidImpact() { HapticsManager.shared.rigidImpact() }
    static func softImpact() { HapticsManager.shared.softImpact() }
    static func selectionFeedback() { HapticsManager.shared.selectionFeedback() }
    static func successFeedback() { HapticsManager.shared.successFeedback() }
    static func warningFeedback() { HapticsManager.shared.warningFeedback() }
    static func errorFeedback() { HapticsManager.shared.errorFeedback() }
    static func heartbeatPulse() { HapticsManager.shared.heartbeatPulse() }
}
