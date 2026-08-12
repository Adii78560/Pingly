//
//  HapticsManager.swift
//  Pingly
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
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
    
    func mediumImpact() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }
    
    func heavyImpact() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
    }
    
    func rigidImpact() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred()
    }
    
    func softImpact() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred()
    }
    
    // MARK: - Selection Feedback
    
    func selectionFeedback() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
    
    // MARK: - Notification Feedback
    
    func successFeedback() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }
    
    func warningFeedback() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }
    
    func errorFeedback() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }
    
    // MARK: - Tactical Heartbeat Pulse Pattern (Lub-Dub)
    
    /// Triggers a double-pulse heartbeat pattern (light tap followed by medium tap)
    func heartbeatPulse() {
        let generator1 = UIImpactFeedbackGenerator(style: .light)
        generator1.prepare()
        generator1.impactOccurred()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let generator2 = UIImpactFeedbackGenerator(style: .medium)
            generator2.prepare()
            generator2.impactOccurred()
        }
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
