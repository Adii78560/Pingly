//
//  BackgroundAudioSessionManager.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import AVFoundation
import UIKit
import Combine
import os



/// Manages system AVAudioSession for low-latency background audio processing and route interruptions.
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
    
    /// Configures system AVAudioSession for simultaneous record & playback in foreground and background.
    func configureAudioSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
                        .mixWithOthers
                    ]
                )
                try session.setPreferredSampleRate(16000.0)
                try session.setPreferredIOBufferDuration(0.005) // 5ms low latency frame buffer
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                
                DispatchQueue.main.async {
                    self.isAudioSessionActive = true
                }
                self.checkCurrentRoute()
                AppLogger.audio.info("AVAudioSession successfully activated asynchronously for PTT")
            } catch {
                AppLogger.audio.error("Failed to set audio session category: \(error.localizedDescription)")
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
                AppLogger.audio.info("AVAudioSession successfully deactivated for battery conservation")
            } catch {
                AppLogger.audio.warning("Could not deactivate AVAudioSession: \(error.localizedDescription)")
            }
        }
    }


    
    /// Requests background execution time from iOS to prevent network socket suspension during live stream.
    func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Pingly.PTT.BackgroundStream") { [weak self] in
            self?.endBackgroundTask()
        }
        
        // Safety timer to automatically end background task before iOS 30-second watchdog limit
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

    
    // MARK: - Handlers & Notifications
    
    private func setupNotificationObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            AppLogger.audio.warning("Audio Interruption Began (e.g. Phone call)")
            AudioStreamEngine.shared.stopCapture()
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    configureAudioSession()
                }
            }
        @unknown default:
            break
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        checkCurrentRoute()
    }
    
    private func checkCurrentRoute() {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        let hasHeadset = currentRoute.outputs.contains { output in
            return output.portType == .bluetoothHFP ||
                   output.portType == .bluetoothA2DP ||
                   output.portType == .headphones
        }
        DispatchQueue.main.async {
            self.isHeadsetConnected = hasHeadset
        }
    }
}
