//
//  VoiceMessagePlayerManager.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 26/08/26.
//

import Foundation
import AVFoundation
import Combine
import os

/// Singleton manager for playing back recorded voice notes in channel history with progress tracking.
final class VoiceMessagePlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    
    static let shared = VoiceMessagePlayerManager()
    
    @Published var playingMessageID: UUID? = nil
    @Published var isPlaying: Bool = false
    @Published var playbackProgress: Double = 0.0 // 0.0 to 1.0
    @Published var currentTime: TimeInterval = 0.0
    
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private let audioSessionQueue = DispatchQueue(label: "com.relyvo.audio.playerSessionQueue", qos: .userInitiated)
    
    private override init() {
        super.init()
    }
    
    /// Checks if the audio file exists on disk (either M4A or legacy WAV).
    func isAudioFileAvailable(for message: VoiceMessage) -> Bool {
        return FileManager.default.fileExists(atPath: message.audioFilePath)
    }
    
    func togglePlay(for message: VoiceMessage) {
        if playingMessageID == message.id {
            if isPlaying {
                pause()
            } else {
                resume()
            }
            return
        }
        play(message: message)
    }
    
    func play(message: VoiceMessage) {
        stop()
        
        let fileURL = URL(fileURLWithPath: message.audioFilePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            AppLogger.audio.error("[VOICE_PLAYER] Voice file not found at path: \(fileURL.path)")
            return
        }
        
        audioSessionQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                // Category .playback ONLY supports [.duckOthers] or [.mixWithOthers].
                // Passing .defaultToSpeaker with .playback triggers OSStatus -50 (kAudio_ParamError).
                try session.setCategory(.playback, mode: .default, options: [.duckOthers])
                try session.setActive(true)
                
                let player = try AVAudioPlayer(contentsOf: fileURL)
                
                DispatchQueue.main.async {
                    player.delegate = self
                    player.prepareToPlay()
                    player.play()
                    
                    self.audioPlayer = player
                    self.playingMessageID = message.id
                    self.isPlaying = true
                    self.playbackProgress = 0.0
                    self.currentTime = 0.0
                    
                    Task {
                        await SwiftDataService.shared.persistenceActor.markVoiceMessageAsPlayed(id: message.id)
                    }
                    self.startProgressTimer()
                    AppLogger.audio.info("[VOICE_PLAYER] Playing voice note cleanly: \(fileURL.lastPathComponent)")
                }
            } catch {
                AppLogger.audio.error("[VOICE_PLAYER] Failed to configure session or play audio file: \(error.localizedDescription)")
            }
        }
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }
    
    func resume() {
        audioPlayer?.play()
        isPlaying = true
        startProgressTimer()
    }
    
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingMessageID = nil
        isPlaying = false
        playbackProgress = 0.0
        currentTime = 0.0
        stopProgressTimer()
    }
    
    func seek(to progress: Double) {
        guard let player = audioPlayer else { return }
        let clamped = max(0.0, min(1.0, progress))
        player.currentTime = clamped * player.duration
        currentTime = player.currentTime
        playbackProgress = clamped
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.stop()
            AppLogger.audio.info("[VOICE_PLAYER] Playback finished successfully.")
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            self.stop()
            AppLogger.audio.error("[VOICE_PLAYER] Decode error occurred: \(error?.localizedDescription ?? "unknown")")
        }
    }
    
    // MARK: - Progress Tracking Timer
    
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer, player.duration > 0 else { return }
            self.currentTime = player.currentTime
            self.playbackProgress = player.currentTime / player.duration
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
