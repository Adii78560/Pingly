//
//  SOSAlarmManager.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 21/09/26.
//

import Foundation
import AVFoundation
import os
import OSLog

/// Handles the generation and routing of emergency SOS acoustic alarms.
actor SOSAlarmManager {
    static let shared = SOSAlarmManager()
    
    private var lastAlarmTriggerDate: Date?
    private var lastAlarmMessageID: UUID?
    
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var isPlaying = false
    
    private let audioSessionQueue = DispatchQueue(label: "com.relyvo.audio.sosSessionQueue", qos: .userInitiated)
    
    private init() {}
    
    /// Triggers a 1.0 second dual-tone loudspeaker siren.
    func playEmergencyAlarm(for messageID: UUID) {
        let now = Date()
        if let lastDate = lastAlarmTriggerDate,
           let lastID = lastAlarmMessageID,
           lastID == messageID,
           now.timeIntervalSince(lastDate) < 5.0 {
            AppLogger.multipeer.info("[SOS_ALARM_DEBOUNCE] Dropping duplicate acoustic alarm trigger for message \(messageID)")
            return
        }
        
        lastAlarmTriggerDate = now
        lastAlarmMessageID = messageID
        
        if isPlaying {
            engine?.stop()
            playerNode?.stop()
        }
        
        isPlaying = true
        
        audioSessionQueue.async { [weak self] in
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
                try session.setActive(true)
            } catch {
                AppLogger.multipeer.error("[SOS_ALARM_ERROR] Failed to override audio session for speaker playback: \(error.localizedDescription)")
            }
            
            Task {
                // 2. Synthesize 1-second dual-tone siren
                await self?.setupAndPlaySyntheticSiren()
            }
        }
    }
    
    private func setupAndPlaySyntheticSiren() {
        engine = AVAudioEngine()
        guard let engine = engine else { return }
        
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        
        let duration: TimeInterval = 1.0
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        
        buffer.frameLength = frameCount
        let channelData = buffer.floatChannelData![0]
        
        let freq1: Float = 800.0
        let freq2: Float = 1200.0
        let cycleDuration: TimeInterval = 0.1 // Switch every 100ms
        let framesPerCycle = Int(format.sampleRate * cycleDuration)
        
        var phase: Float = 0.0
        
        for frame in 0..<Int(frameCount) {
            let isFreq1 = (frame / framesPerCycle) % 2 == 0
            let currentFreq = isFreq1 ? freq1 : freq2
            
            let phaseIncrement = (2.0 * .pi * currentFreq) / Float(format.sampleRate)
            
            // Square wave for harsh siren
            channelData[frame] = sin(phase) > 0 ? 1.0 : -1.0
            
            phase += phaseIncrement
            if phase > 2.0 * .pi {
                phase -= 2.0 * .pi
            }
        }
        
        playerNode = AVAudioPlayerNode()
        guard let playerNode = playerNode else { return }
        
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        do {
            try engine.start()
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
                Task {
                    await self?.cleanupAlarm()
                }
            })
            
            // Ensure maximum volume out of engine mixer
            engine.mainMixerNode.outputVolume = 1.0
            playerNode.volume = 1.0
            playerNode.play()
            
            AppLogger.multipeer.warning("[SOS_ALARM_PLAYING] Sounding dual-tone acoustic alarm through loudspeaker")
        } catch {
            AppLogger.multipeer.error("[SOS_ALARM_ERROR] Failed to start AVAudioEngine: \(error.localizedDescription)")
            Task {
                cleanupAlarm()
            }
        }
    }
    
    private func cleanupAlarm() {
        isPlaying = false
        playerNode?.stop()
        engine?.stop()
        
        // Restore AVAudioSession state for Walkie-Talkie
        audioSessionQueue.async {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers])
                try session.setActive(true)
                AppLogger.multipeer.info("[SOS_ALARM_CLEANUP] Restored AVAudioSession to playAndRecord (voiceChat)")
            } catch {
                AppLogger.multipeer.error("[SOS_ALARM_ERROR] Failed to restore audio session: \(error.localizedDescription)")
            }
        }
    }
}
