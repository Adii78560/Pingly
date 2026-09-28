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
    
    // MARK: - Reference Counting Audio Session Lifecycle
    private var activeSessionCount: Int = 0
    private let sessionCountLock = NSLock()
    private var deactivationTimer: DispatchSourceTimer?
    
    func incrementActiveSession() {
        sessionCountLock.lock()
        activeSessionCount += 1
        let count = activeSessionCount
        deactivationTimer?.cancel()
        deactivationTimer = nil
        let needsConfig = !isAudioSessionActive
        sessionCountLock.unlock()
        AppLogger.audio.info("[PTT_DIAG][BackgroundAudioSessionManager] incrementActiveSession() -> count=\(count)")
        if count == 1 || needsConfig {
            configureAudioSession()
        }
    }
    
    func decrementActiveSession() {
        sessionCountLock.lock()
        activeSessionCount = max(0, activeSessionCount - 1)
        let count = activeSessionCount
        if count == 0 {
            // Graceful cooldown: delay deactivation by 4.0s to prevent tearing down CoreAudio RemoteIO between speech turns
            deactivationTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: audioSessionQueue)
            timer.schedule(deadline: .now() + 4.0)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.sessionCountLock.lock()
                let currentCount = self.activeSessionCount
                self.sessionCountLock.unlock()
                if currentCount == 0 {
                    self.deactivateAudioSession()
                }
            }
            deactivationTimer = timer
            timer.resume()
        }
        sessionCountLock.unlock()
        AppLogger.audio.info("[PTT_DIAG][BackgroundAudioSessionManager] decrementActiveSession() -> count=\(count)")
    }
    
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
                        .allowBluetoothHFP,
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
                AppLogger.audio.info("[PTT_DIAG][BackgroundAudioSessionManager] ✅ AVAudioSession configured & activated. category=\(session.category.rawValue) sampleRate=\(session.sampleRate) ioBufferDuration=\(session.ioBufferDuration)")
                self.checkCurrentRoute()
            } catch {
                AppLogger.audio.error("[PTT_DIAG][BackgroundAudioSessionManager] ❌ AVAudioSession configure FAILED: \(error.localizedDescription)")
            }
        }
    }
    
    func deactivateAudioSession() {
        audioSessionQueue.async { [weak self] in
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                AppLogger.audio.info("[PTT_DIAG][BackgroundAudioSessionManager] AVAudioSession deactivated")
                DispatchQueue.main.async {
                    self?.isAudioSessionActive = false
                }
            } catch {
                AppLogger.audio.error("[PTT_DIAG][BackgroundAudioSessionManager] ❌ AVAudioSession deactivation FAILED: \(error.localizedDescription)")
            }
        }
    }
    
    /// Applies loudspeaker policy: routes to speaker unless a headset/AirPods/Bluetooth device is attached.
    func applyLoudspeakerPolicy(for session: AVAudioSession = AVAudioSession.sharedInstance()) {
        audioSessionQueue.async {
            guard session.category == .playAndRecord else {
                return
            }
            
            let hasHeadset = self.isExternalOutputConnected(session: session)
            let isAlreadySpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
            
            do {
                if hasHeadset {
                    try session.overrideOutputAudioPort(.none)
                } else if !isAlreadySpeaker {
                    try session.overrideOutputAudioPort(.speaker)
                }
            } catch {
                AppLogger.multipeer.error("Failed to apply loudspeaker policy: \(error.localizedDescription)")
            }
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
        
    }
    
    /// Releases iOS background task lock.
    func endBackgroundTask() {
        backgroundTaskTimer?.invalidate()
        backgroundTaskTimer = nil
        
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
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
            
            // 1. If transmitting (holding PTT): immediately release floor and stop mic capture
            if WalkieTalkieNetworkManager.shared.isFloorLockedBySelf {
                WalkieTalkieNetworkManager.shared.releaseFloor()
            } else {
                AudioStreamEngine.shared.stopCapture()
            }
            
            // 2. Stop receiving live playback and voice note playback
            AudioStreamEngine.shared.playerNode.stop()
            VoiceMessagePlayerManager.shared.stop()
            
            
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                _ = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            }
            
            
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
        
        audioSessionQueue.async { [weak self] in
            switch reason {
            case .oldDeviceUnavailable:
                // E.g. AirPods disconnected / Bluetooth disconnected
                // Pause active replay to avoid blasting audio unexpectedly
                DispatchQueue.main.async {
                    VoiceMessagePlayerManager.shared.pause()
                }
                do {
                    try session.overrideOutputAudioPort(.speaker)
                } catch {}
                
            case .newDeviceAvailable:
                // E.g. AirPods connected. Let iOS route it to the new device automatically.
                break
                
            case .categoryChange, .override, .wakeFromSleep:
                self?.applyLoudspeakerPolicy(for: session)
                
            default:
                self?.applyLoudspeakerPolicy(for: session)
            }
            
            self?.checkCurrentRoute()
        }
    }
    
    private func checkCurrentRoute() {
        let hasHeadset = isExternalOutputConnected()
        DispatchQueue.main.async {
            self.isHeadsetConnected = hasHeadset
        }
    }
    
    // MARK: - Media Server Reset Recovery
    
    @objc func handleMediaServicesLost(notification: Notification) {
        DispatchQueue.main.async {
            self.isAudioSessionActive = false
        }
    }
    
    @objc func handleMediaServicesReset(notification: Notification) {
        configureAudioSession()
        AudioStreamEngine.shared.reconstructAudioEngine()
    }
}
