//
//  RadioCallViewModel.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import Combine
import os

/// View model driving the Push-To-Talk (PTT) Off-Grid Radio Call screen
final class RadioCallViewModel: ObservableObject {
    
    /// The UserDefaults key for persisting the active channel across app restarts.
    private static let activeChannelKey = "com.RaiEnterprise.Relyvo.activeChannel"
    /// The UserDefaults key for user-created custom channels.
    static let customChannelsKey = "com.RaiEnterprise.Relyvo.customChannels"

    @Published var session: RadioSession = RadioSession()
    @Published var isPTTPressed: Bool = false
    @Published var selectedChannel: String = UserDefaults.standard.string(forKey: "com.RaiEnterprise.Relyvo.activeChannel") ?? "CH-1 EMERGENCY" {
        didSet {
            let newChannel = self.selectedChannel
            // Persist active channel so app restores the correct channel after a relaunch.
            UserDefaults.standard.set(newChannel, forKey: RadioCallViewModel.activeChannelKey)
            // Immediately halt any in-flight audio from the previous channel so it
            // cannot bleed into the newly selected channel's session.
            networkManager.stopActiveAudioStream()
            loadSwiftDataTranscripts()
            networkManager.selectedChannel = newChannel
            multipeerService.activeChannelID = newChannel
            AppLogger.multipeer.info("[ChannelSwitch] Active channel changed to: \(newChannel)")
        }
    }
    
    @Published var connectedPeerName: String = "Searching for Peers..."
    @Published var connectedPeerRSSI: Int = 0
    @Published var isConnected: Bool = false
    @Published var isAddedToMessages: Bool = false
    @Published var latestTextSnippet: String = "Standing by for live voice transcripts..."
    @Published var transcriptHistory: [VoiceTranscript] = []

    
    var channelPeers: [PeerDevice] {
        return multipeerService.connectedPeers
    }
    
    func addUserToMessages(peer: PeerDevice) {
        NotificationCenter.default.post(
            name: .didAddPeerToMessages,
            object: nil,
            userInfo: [
                "peerName": peer.displayName,
                "nodeID": peer.id,
                "channel": selectedChannel
            ]
        )
        isAddedToMessages = true
        HapticManager.successFeedback()
        AppLogger.multipeer.info("Added AirDrop peer '\(peer.displayName)' (NodeID: \(peer.id)) on \(self.selectedChannel) to Messages directory.")
    }

    
    var localUserHandle: String {

        return UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
    }
    
    @Published var availableChannels: [String] = {
        let defaultChannels = ["CH-1 EMERGENCY", "CH-2 RESCUE MESH", "CH-3 MOUNTAIN OPS", "CH-4 GENERAL P2P"]
        // Migrate from legacy key if needed
        let legacySaved = UserDefaults.standard.stringArray(forKey: "Relayn.CustomChannels") ?? []
        let saved = UserDefaults.standard.stringArray(forKey: "com.RaiEnterprise.Relyvo.customChannels") ?? legacySaved
        // Preserve insertion order: defaults first, then unique custom additions.
        // Avoid Set which randomises order and breaks the CH-1 EMERGENCY priority position.
        var result = defaultChannels
        for ch in saved where !result.contains(ch) {
            result.append(ch)
        }
        return result
    }()
    
    var filteredTranscripts: [VoiceTranscript] {
        transcriptHistory.filter { $0.channel.uppercased() == selectedChannel.uppercased() }
    }
    
    private let multipeerService: MultipeerService
    private let audioService: RadioAudioService
    private let networkManager = WalkieTalkieNetworkManager.shared
    private let speechTranscriber = SpeechTranscriberManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    var activeStatusText: String {
        if !isConnected { return "OFFLINE" }
        if networkManager.isFloorLockedBySelf { return "TRANSMITTING" }
        if networkManager.activeFloorSenderID != nil { return "RECEIVING" }
        return "READY"
    }
    
    init(multipeerService: MultipeerService, audioService: RadioAudioService) {
        self.multipeerService = multipeerService
        self.audioService = audioService
        self.networkManager.selectedChannel = selectedChannel
        self.multipeerService.activeChannelID = selectedChannel
        setupSubscriptions()
        loadSwiftDataTranscripts()
    }
    
    func loadSwiftDataTranscripts() {
        let saved = SwiftDataService.shared.fetchTranscripts(for: selectedChannel)
        for item in saved {
            if !transcriptHistory.contains(where: { $0.id == item.id }) {
                transcriptHistory.append(item)
            }
        }
    }

    
    func createChannel(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return }
        // Bug fix: was "CH- " + trimmed (with trailing space), producing "CH- MYNAME".
        let channelName = trimmed.hasPrefix("CH-") ? trimmed : "CH-" + trimmed
        if !availableChannels.contains(channelName) {
            availableChannels.append(channelName)
            var saved = UserDefaults.standard.stringArray(forKey: RadioCallViewModel.customChannelsKey) ?? []
            saved.append(channelName)
            UserDefaults.standard.set(saved, forKey: RadioCallViewModel.customChannelsKey)
        }
        selectedChannel = channelName
        multipeerService.broadcastChannelSync(channelName: channelName)
        HapticManager.successFeedback()
        AppLogger.multipeer.info("Created and broadcasted custom Walkie-Talkie channel: \(channelName)")
    }
    
    func shareActiveChannel() {
        multipeerService.broadcastChannelSync(channelName: selectedChannel)
        HapticManager.successFeedback()
    }
    
    /// Deletes a custom channel from the available list and UserDefaults.
    ///
    /// Safety rules:
    /// - Default channels ("CH-1 EMERGENCY" through "CH-4 GENERAL P2P") cannot be deleted.
    /// - If the channel being deleted is currently selected, `selectedChannel` falls back to
    ///   "CH-1 EMERGENCY" before the deletion completes, preventing orphaned state.
    func deleteChannel(named channelName: String) {
        let defaultChannels = ["CH-1 EMERGENCY", "CH-2 RESCUE MESH", "CH-3 MOUNTAIN OPS", "CH-4 GENERAL P2P"]
        guard !defaultChannels.contains(channelName) else {
            AppLogger.multipeer.warning("[ChannelDelete] Attempted to delete protected default channel: \(channelName). Ignored.")
            return
        }
        
        // If we are currently on the channel being deleted, switch first to avoid orphaned state.
        // This triggers selectedChannel.didSet which also stops in-flight audio.
        if selectedChannel == channelName {
            AppLogger.multipeer.info("[ChannelDelete] Active channel '\(channelName)' deleted — falling back to CH-1 EMERGENCY")
            selectedChannel = "CH-1 EMERGENCY"
        }
        
        // Remove from in-memory list
        availableChannels.removeAll { $0 == channelName }
        
        // Remove from UserDefaults (canonical key only — legacy key is read-only on migration)
        var saved = UserDefaults.standard.stringArray(forKey: RadioCallViewModel.customChannelsKey) ?? []
        saved.removeAll { $0 == channelName }
        UserDefaults.standard.set(saved, forKey: RadioCallViewModel.customChannelsKey)
        
        HapticManager.warningFeedback()
        AppLogger.multipeer.info("[ChannelDelete] Removed channel '\(channelName)' from available channels list")
    }
    
    private func setupSubscriptions() {
        // Observe channel sync invites from nearby P2P peers
        NotificationCenter.default.publisher(for: .didReceiveChannelSync)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let channelName = notification.userInfo?["channelName"] as? String,
                      let creator = notification.userInfo?["creator"] as? String else { return }
                
                if !self.availableChannels.contains(channelName) {
                    self.availableChannels.append(channelName)
                    // Persist peer-synced channel under the canonical key.
                    var saved = UserDefaults.standard.stringArray(forKey: RadioCallViewModel.customChannelsKey) ?? []
                    saved.append(channelName)
                    UserDefaults.standard.set(saved, forKey: RadioCallViewModel.customChannelsKey)
                }
                self.latestTextSnippet = "\(creator) shared channel: \(channelName)"
                HapticManager.successFeedback()
                AppLogger.multipeer.info("Auto-synced custom channel \(channelName) from \(creator)")
            }
            .store(in: &cancellables)
        
        // Listen for newly saved voice transcripts to update channel history
        NotificationCenter.default.publisher(for: .didSaveVoiceTranscript)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.loadSwiftDataTranscripts()
                if let last = self.filteredTranscripts.last {
                    self.latestTextSnippet = "\(last.speakerName): \"\(last.text)\""
                }
            }
            .store(in: &cancellables)


            
        // Live speech recognition snippet preview
        speechTranscriber.$currentTranscriptText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] liveText in
                guard let self = self, !liveText.isEmpty else { return }
                let speaker = self.isPTTPressed ? self.localUserHandle : self.connectedPeerName
                self.latestTextSnippet = "\(speaker): \"\(liveText)...\""
            }
            .store(in: &cancellables)
        
        // Observe WalkieTalkieNetworkManager floor locks
        networkManager.$isFloorLockedBySelf
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLocked in
                self?.isPTTPressed = isLocked
                self?.session.isBroadcasting = isLocked
            }
            .store(in: &cancellables)
        
        networkManager.$activeFloorSenderID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] senderID in
                guard let self = self else { return }
                if let senderID = senderID, senderID != "LOCAL_SELF" {
                    self.session.isReceivingAudio = true
                    self.session.activeSpeakerName = self.connectedPeerName
                } else {
                    self.session.isReceivingAudio = false
                    self.session.activeSpeakerName = nil
                }
            }
            .store(in: &cancellables)

        
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
        
        AudioStreamEngine.shared.$currentAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.session.audioLevel = level
            }
            .store(in: &cancellables)

        
        // Connected peer count updates & delivery status flushing
        multipeerService.connectedPeersPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                guard let self = self else { return }
                self.session.connectedPeersCount = peers.count
                if let firstPeer = peers.first {
                    self.connectedPeerName = firstPeer.displayName
                    self.connectedPeerRSSI = firstPeer.rssi
                    self.isConnected = true
                    
                    // Mark pending offline transcripts as delivered (GREEN) when peers join channel
                    SwiftDataService.shared.markTranscriptsAsDelivered(for: self.selectedChannel)
                    NotificationCenter.default.post(name: .didSaveVoiceTranscript, object: nil)
                } else {
                    self.connectedPeerName = "Searching for Peers..."
                    self.connectedPeerRSSI = 0
                    self.isConnected = false
                }
            }
            .store(in: &cancellables)
    }
    
    func toggleAddedToMessages() {
        isAddedToMessages.toggle()
        HapticManager.successFeedback()
    }
    
    func disconnect() {
        if isPTTPressed {
            stopTransmittingVoice()
        }
        isConnected = false
        multipeerService.stopAdvertisingAndBrowsing()
        HapticManager.warningFeedback()
    }
    
    func startTransmittingVoice() {
        let handle = localUserHandle
        session.activeSpeakerName = handle
        let acquired = networkManager.acquireFloor()
        if acquired {
            speechTranscriber.startTranscribing(speakerName: handle, channel: selectedChannel, sessionID: self.networkManager.currentSessionID)
            HapticManager.mediumImpact()
            AppLogger.audio.info("Acquired floor lock; transmitting PTT voice call on \(self.selectedChannel) with sessionID \(self.networkManager.currentSessionID?.uuidString ?? "nil")")
        } else {
            HapticManager.warningFeedback()
        }
    }

    
    func stopTransmittingVoice() {
        speechTranscriber.stopTranscribing()
        networkManager.releaseFloor()
        session.activeSpeakerName = nil
        HapticManager.lightImpact()
        AppLogger.audio.info("Released floor lock; stopped transmitting PTT voice call")
    }
}




