//
//  BackgroundAudioSessionManager.swift
//  Relyvo
//
//  Production-Grade AVAudioSession Management, Route Routing, Interruption & Media Server Reset Engine
//

import Foundation
import AVFoundation
import UIKit
import Combine
import os

/// Manages system AVAudioSession for low-latency PTT background audio processing, loudspeaker routing, and interruptions.
final class BackgroundAudioSessionManager: NSObject, ObservableObject {
    
    static let shared = BackgroundAudioSessionManager()
    
    @Published private(set) var isAudioSessionActive = false
    @Published private(set) var isHeadsetConnected = false
    
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskTimer: Timer?
    
    private override init() {
        super.init()
        setupNotificationObservers()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public Controls
    
    private let audioSessionQueue = DispatchQueue(label: "com.relyvo.audio.backgroundSessionQueue", qos: .userInitiated)
    
    /// Configures system AVAudioSession for simultaneous record & playback in foreground and background with loud loudspeaker policy.
    func configureAudioSession() {
        audioSessionQueue.async { [weak self] in
            guard let self = self else { return }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [
                        .defaultToSpeaker,
                        .allowBluetooth,
                        .allowBluetoothA2DP,
                        .duckOthers
                    ]
                )
                try session.setPreferredSampleRate(16000.0)
                try session.setPreferredIOBufferDuration(0.005) // 5ms low latency frame buffer
                
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                
                // Apply loudspeaker override if no external headset/Bluetooth is connected (MUST be called AFTER setActive)
                self.applyLoudspeakerPolicy(for: session)
                
                DispatchQueue.main.async {
                    self.isAudioSessionActive = true
                }
                self.checkCurrentRoute()
                AppLogger.audio.info("[AUDIO_SESSION_CONFIG] AVAudioSession configured (.playAndRecord, .voiceChat, .duckOthers, .defaultToSpeaker)")
            } catch {
                AppLogger.audio.error("[AUDIO_SESSION_ERR] Failed to configure AVAudioSession: \(error.localizedDescription)")
            }
        }
    }
    
    /// Deactivates system AVAudioSession to power down hardware microphone and conserve battery.
    func deactivateAudioSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                DispatchQueue.main.async {
                    self?.isAudioSessionActive = false
                }
                AppLogger.audio.info("[AUDIO_SESSION_DEACTIVATE] AVAudioSession deactivated")
            } catch {
                AppLogger.audio.warning("[AUDIO_SESSION_WARN] Could not deactivate AVAudioSession: \(error.localizedDescription)")
            }
        }
    }
    
    /// Applies loudspeaker policy: routes to speaker unless a headset/AirPods/Bluetooth device is attached.
    func applyLoudspeakerPolicy(for session: AVAudioSession = AVAudioSession.sharedInstance()) {
        guard session.category == .playAndRecord else {
            AppLogger.audio.info("[AUDIO_ROUTE_POLICY] Skipped port override: session category is \(session.category.rawValue), not .playAndRecord")
            return
        }
        
        let hasHeadset = isExternalOutputConnected(session: session)
        let isAlreadySpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        
        do {
            if hasHeadset {
                try session.overrideOutputAudioPort(.none)
                AppLogger.audio.info("[AUDIO_ROUTE_POLICY] Headset/Bluetooth detected — speaker override cleared (.none)")
            } else if !isAlreadySpeaker {
                try session.overrideOutputAudioPort(.speaker)
                AppLogger.audio.info("[AUDIO_ROUTE_POLICY] Internal speaker active — loud loudspeaker override applied (.speaker)")
            } else {
                AppLogger.audio.info("[AUDIO_ROUTE_POLICY] Route is already builtInSpeaker — redundant override skipped")
            }
        } catch {
            AppLogger.audio.error("[AUDIO_ROUTE_ERR] Failed to set port override: \(error.localizedDescription)")
        }
    }
    
    /// Evaluates if external outputs (AirPods, Bluetooth HFP/A2DP, Wired Headphones) are active.
    func isExternalOutputConnected(session: AVAudioSession = AVAudioSession.sharedInstance()) -> Bool {
        return session.currentRoute.outputs.contains { output in
            output.portType == .bluetoothHFP ||
            output.portType == .bluetoothA2DP ||
            output.portType == .bluetoothLE ||
            output.portType == .headphones ||
            output.portType == .airPlay
        }
    }
    
    // MARK: - Background Task Execution
    
    /// Requests background execution time from iOS to prevent network audio streaming suspension.
    func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Relyvo.PTT.BackgroundStream") { [weak self] in
            self?.endBackgroundTask()
        }
        
        backgroundTaskTimer?.invalidate()
        backgroundTaskTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: false) { [weak self] _ in
            self?.endBackgroundTask()
        }
        
        AppLogger.audio.info("Background PTT execution task started.")
    }
    
    /// Releases iOS background task lock.
    func endBackgroundTask() {
        backgroundTaskTimer?.invalidate()
        backgroundTaskTimer = nil
        
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        AppLogger.audio.info("Background PTT execution task ended.")
    }
    
    // MARK: - Handlers & Notification Observers
    
    private func setupNotificationObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleMediaServicesLost), name: AVAudioSession.mediaServicesWereLostNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleMediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }
    
    // MARK: - Interruption Handling (Phone calls, Siri, Alarms)
    
    @objc func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            AppLogger.audio.warning("[AUDIO_INTERRUPTION_BEGAN] Interruption started (phone call/alarm) — releasing PTT floor and pausing streams")
            
            // 1. If transmitting (holding PTT): immediately release floor and stop mic capture
            if WalkieTalkieNetworkManager.shared.isFloorLockedBySelf {
                WalkieTalkieNetworkManager.shared.releaseFloor()
            } else {
                AudioStreamEngine.shared.stopCapture()
            }
            
            // 2. Stop receiving live playback and voice note playback
            AudioStreamEngine.shared.playerNode.stop()
            VoiceMessagePlayerManager.shared.stop()
            
            AppLogger.audio.info("[AUDIO_INTERRUPTION_BEGAN] floorReleased=true")
            
        case .ended:
            var shouldResume = false
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            }
            
            AppLogger.audio.info("[AUDIO_INTERRUPTION_ENDED] shouldResume=\(shouldResume)")
            
            // Reactivate audio session and restore engine nodes to ready state without auto-locking floor
            configureAudioSession()
            AudioStreamEngine.shared.preparePlaybackEngine()
            
        @unknown default:
            break
        }
    }
    
    // MARK: - Audio Route Change Handling (AirPods / Bluetooth / Speaker)
    
    @objc func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            checkCurrentRoute()
            return
        }
        
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { $0.portName }
        AppLogger.audio.info("[AUDIO_ROUTE_CHANGED] reason=\(reasonValue) currentRoute=\(outputs.joined(separator: ", "))")
        
        switch reason {
        case .oldDeviceUnavailable:
            // E.g. AirPods disconnected / Bluetooth disconnected
            AppLogger.audio.warning("[AUDIO_ROUTE_CHANGED] Old device unavailable (AirPods disconnected) — reverting to loudspeaker")
            // Pause active replay to avoid blasting audio unexpectedly
            VoiceMessagePlayerManager.shared.pause()
            applyLoudspeakerPolicy(for: session)
            
        case .newDeviceAvailable:
            // E.g. AirPods connected
            AppLogger.audio.info("[AUDIO_ROUTE_CHANGED] New device available (AirPods connected) — clearing speaker override")
            applyLoudspeakerPolicy(for: session)
            
        case .categoryChange, .override, .wakeFromSleep:
            applyLoudspeakerPolicy(for: session)
            
        default:
            applyLoudspeakerPolicy(for: session)
        }
        
        checkCurrentRoute()
    }
    
    private func checkCurrentRoute() {
        let hasHeadset = isExternalOutputConnected()
        DispatchQueue.main.async {
            self.isHeadsetConnected = hasHeadset
        }
    }
    
    // MARK: - Media Server Reset Recovery
    
    @objc func handleMediaServicesLost(notification: Notification) {
        AppLogger.audio.error("[AUDIO_MEDIA_SERVER_LOST] CoreAudio media services lost — marking inactive")
        DispatchQueue.main.async {
            self.isAudioSessionActive = false
        }
    }
    
    @objc func handleMediaServicesReset(notification: Notification) {
        AppLogger.audio.warning("[AUDIO_MEDIA_SERVER_RESET] CoreAudio media services reset — reconstructing engine & session")
        configureAudioSession()
        AudioStreamEngine.shared.reconstructAudioEngine()
        AppLogger.audio.info("[AUDIO_MEDIA_SERVER_RESET] engineRebuilt=true")
    }
}
