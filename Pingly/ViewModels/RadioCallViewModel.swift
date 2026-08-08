//
//  RadioCallViewModel.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import Combine
import os

/// View model driving the Push-To-Talk (PTT) Off-Grid Radio Call screen
final class RadioCallViewModel: ObservableObject {
    
    @Published var session: RadioSession = RadioSession()
    @Published var isPTTPressed: Bool = false
    @Published var selectedChannel: String = "CH-1 EMERGENCY"
    
    let availableChannels = ["CH-1 EMERGENCY", "CH-2 RESCUE MESH", "CH-3 MOUNTAIN OPS", "CH-4 GENERAL P2P"]
    
    private let multipeerService: MultipeerService
    private let audioService: RadioAudioService
    private var cancellables = Set<AnyCancellable>()
    
    init(multipeerService: MultipeerService, audioService: RadioAudioService) {
        self.multipeerService = multipeerService
        self.audioService = audioService
        setupSubscriptions()
    }
    
    private func setupSubscriptions() {
        // Microphone PCM audio stream -> send via MultipeerConnectivity
        audioService.audioChunkPublisher
            .sink { [weak self] audioData in
                self?.multipeerService.sendAudioStream(data: audioData)
            }
            .store(in: &cancellables)
        
        // Dynamic audio level updates for PTT waveform visualizer
        audioService.$currentAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.session.audioLevel = level
            }
            .store(in: &cancellables)
        
        // Incoming audio stream from remote peer
        multipeerService.receivedAudioDataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] audioData in
                guard let self = self else { return }
                self.session.isReceivingAudio = true
                self.session.activeSpeakerName = "Remote Peer"
                self.audioService.playReceivedAudioChunk(audioData)
            }
            .store(in: &cancellables)
        
        // Connected peer count updates
        multipeerService.connectedPeersPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.session.connectedPeersCount = peers.count
            }
            .store(in: &cancellables)
    }
    
    func startTransmittingVoice() {
        isPTTPressed = true
        session.isBroadcasting = true
        let handle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        session.activeSpeakerName = handle
        audioService.startRecordingPTT()
        AppLogger.audio.info("Transmitting PTT radio voice call on \(self.selectedChannel)")
    }
    
    func stopTransmittingVoice() {
        isPTTPressed = false
        session.isBroadcasting = false
        session.activeSpeakerName = nil
        audioService.stopRecordingPTT()
        AppLogger.audio.info("Stopped transmitting PTT radio voice call")
    }
}
