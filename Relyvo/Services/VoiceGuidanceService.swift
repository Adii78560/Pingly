//
//  VoiceGuidanceService.swift
//  Relyvo
//
//  Created by Senior iOS Developer.
//

import Foundation
import AVFoundation
import os

/// Handles text-to-speech voice guidance announcements for Navigation.
final class VoiceGuidanceService: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    
    private let synthesizer = AVSpeechSynthesizer()
    private let debounceInterval: TimeInterval = 10.0
    
    private let queue = DispatchQueue(label: "com.relyvo.voiceguidance", qos: .userInitiated)
    
    // Mutable state protected by queue
    private var lastAnnouncementText: String?
    private var lastAnnouncementTime: Date = .distantPast
    private var hasAnnouncedArrival: Bool = false
    
    override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    func announceManeuver(_ maneuver: RouteManeuver) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            if maneuver.type == .arrive {
                if !self.hasAnnouncedArrival {
                    self.speak("You have arrived at your destination.")
                    self.hasAnnouncedArrival = true
                }
                return
            }
            
            // Generate contextual text based on distance
            let dist = maneuver.distanceFromCurrentPosition
            let text: String
            
            if dist < 30 {
                text = maneuver.instructionText
            } else if dist < 150 {
                text = "In \(Int(dist)) meters, \(maneuver.instructionText)"
            } else if dist < 350 {
                text = "In \(Int(dist)) meters, \(maneuver.instructionText)"
            } else {
                // Too far to constantly announce, skip
                return
            }
            
            let now = Date()
            if text == self.lastAnnouncementText {
                if now.timeIntervalSince(self.lastAnnouncementTime) < self.debounceInterval {
                    return // Debounce exact same utterance
                }
            }
            
            self.speak(text)
            self.lastAnnouncementText = text
            self.lastAnnouncementTime = now
        }
    }
    
    func announceRerouting() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let text = "Recalculating route."
            let now = Date()
            
            if text == self.lastAnnouncementText && now.timeIntervalSince(self.lastAnnouncementTime) < 5.0 {
                return
            }
            
            self.speak(text)
            self.lastAnnouncementText = text
            self.lastAnnouncementTime = now
        }
    }
    
    func stop() {
        queue.async { [weak self] in
            self?.synthesizer.stopSpeaking(at: .immediate)
            self?.hasAnnouncedArrival = false
            self?.lastAnnouncementText = nil
        }
    }
    
    private func speak(_ text: String) {
        // We defer to BackgroundAudioSessionManager implicitly because it has `.duckOthers`.
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        
        // This duckOthers policy is active globally via BackgroundAudioSessionManager.
        synthesizer.speak(utterance)
        AppLogger.audio.info("[VoiceGuidance] Speaking: \(text)")
    }
}
