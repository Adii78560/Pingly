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
    
    @Published var connectedPeerName: String = "Alex's iPhone"
    @Published var connectedPeerRSSI: Int = -42
    @Published var isConnected: Bool = true
    @Published var isAddedToMessages: Bool = false
    @Published var latestTextSnippet: String = "You: \"Roger that, standing by.\""
    
    let availableChannels = ["CH-1 EMERGENCY", "CH-2 RESCUE MESH", "CH-3 MOUNTAIN OPS", "CH-4 GENERAL P2P"]
    
    private let multipeerService: MultipeerService
    private let audioService: RadioAudioService
    private var cancellables = Set<AnyCancellable>()
    
    var activeStatusText: String {
        if !isConnected { return "OFFLINE" }
        if isPTTPressed { return "TRANSMITTING" }
        if session.isReceivingAudio { return "RECEIVING" }
        return "READY"
    }
    
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
                self.session.activeSpeakerName = self.connectedPeerName
                self.audioService.playReceivedAudioChunk(audioData)
            }
            .store(in: &cancellables)
        
        // Connected peer count updates
        multipeerService.connectedPeersPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                guard let self = self else { return }
                self.session.connectedPeersCount = peers.count
                if let firstPeer = peers.first {
                    self.connectedPeerName = firstPeer.displayName
                    self.connectedPeerRSSI = firstPeer.rssi
                    self.isConnected = true
                }
            }
            .store(in: &cancellables)
    }
    
    func toggleAddedToMessages() {
        isAddedToMessages.toggle()
        HapticManager.successFeedback()
    }
    
    func disconnect() {
        isConnected = false
        multipeerService.stopAdvertisingAndBrowsing()
        HapticManager.warningFeedback()
    }
    
    func startTransmittingVoice() {
        guard isConnected else { return }
        isPTTPressed = true
        session.isBroadcasting = true
        let handle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        session.activeSpeakerName = handle
        audioService.startRecordingPTT()
        HapticManager.mediumImpact()
        AppLogger.audio.info("Transmitting PTT radio voice call on \(self.selectedChannel)")
    }
    
    func stopTransmittingVoice() {
        isPTTPressed = false
        session.isBroadcasting = false
        session.activeSpeakerName = nil
        audioService.stopRecordingPTT()
        HapticManager.lightImpact()
        AppLogger.audio.info("Stopped transmitting PTT radio voice call")
    }
}

