//
//  RadioCallViewModel.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import Combine
import CoreLocation
import os
import SwiftData

/// Formalized state machine for Push-To-Talk radio operations
enum PTTSessionState: Equatable {
    case idle                          // Not connected or standby
    case transmitting                  // Local user is talking (floor locked by self)
    case receiving(from: String)       // Remote peer is talking (floor locked by peer name)
    case outOfRange                    // Peer disconnected
    case handsFree                     // Hands-free lock active
}

/// View model driving the Push-To-Talk (PTT) Off-Grid Radio Call screen
final class RadioCallViewModel: ObservableObject {
    
    /// The UserDefaults key for persisting the active channel across app restarts.
    private static let activeChannelKey = "com.RaiEnterprise.Relyvo.activeChannel"
    /// The UserDefaults key for user-created custom channels.
    static let customChannelsKey = "com.RaiEnterprise.Relyvo.customChannels"

    @Published var sessionState: PTTSessionState = .outOfRange
    @Published var session: RadioSession = RadioSession()
    @Published var isPTTPressed: Bool = false
    @Published var activeChannelMembers: [ChannelPeer] = []
    @Published var selectedChannel: String = UserDefaults.standard.string(forKey: "com.RaiEnterprise.Relyvo.activeChannel") ?? "CH-1 EMERGENCY" {
        didSet {
            let newChannel = self.selectedChannel
            // Persist active channel so app restores the correct channel after a relaunch.
            UserDefaults.standard.set(newChannel, forKey: RadioCallViewModel.activeChannelKey)
            // Immediately halt any in-flight audio from the previous channel so it
            // cannot bleed into the newly selected channel's session.
            networkManager.stopActiveAudioStream()
            chatMessages.removeAll()
            loadSwiftDataTranscripts()
            loadChannelMessages(for: newChannel)
            networkManager.selectedChannel = newChannel
            multipeerService.activeChannelID = newChannel
            ChannelPresenceManager.shared.setActiveChannel(newChannel)
            AppLogger.multipeer.info("[DIAG_CHANNEL_SWITCH] localNode=\(NodeIdentity.shared.nodeID) oldChannel=\(oldValue) newChannel=\(newChannel)")
            AppLogger.multipeer.info("[ChannelSwitch] Active channel changed to: \(newChannel)")
            hasUnreadChannelMessages = false
        }
    }
    
    @Published var connectedPeerName: String = "Searching for Peers..."
    @Published var connectedPeerRSSI: Int = 0
    @Published var isConnected: Bool = false
    @Published var isAddedToMessages: Bool = false
    @Published var latestTextSnippet: String = "Standing by for live voice transmissions..."
    @Published var transcriptHistory: [VoiceTranscript] = []
    @Published var voiceMessages: [VoiceMessage] = []
    @Published var chatMessages: [Message] = []
    @Published var messageText: String = ""
    @Published var liveActiveSpeaker: String? = nil
    @Published var activeSOSAlert: SOSAlertPayload? = nil
    @Published var currentLocation: CLLocation? = nil
    @Published var hasUnreadChannelMessages: Bool = false
    @Published var showingChatDrawer: Bool = false
    
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
    private let networkManager = WalkieTalkieNetworkManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    var activeStatusText: String {
        switch sessionState {
        case .outOfRange:
            return "OFFLINE"
        case .idle:
            return "READY"
        case .transmitting:
            return "TRANSMITTING"
        case .receiving:
            return "RECEIVING"
        case .handsFree:
            return "LOCKED"
        }
    }
    
    init(multipeerService: MultipeerService) {
        self.multipeerService = multipeerService
        self.networkManager.selectedChannel = selectedChannel
        self.multipeerService.activeChannelID = selectedChannel
        ChannelPresenceManager.shared.setActiveChannel(selectedChannel)
        setupSubscriptions()
        loadVoiceMessages()
        loadSwiftDataTranscripts()
        loadChannelMessages(for: selectedChannel)
    }
    
    func loadChannelMessages(for channelName: String) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let descriptor = FetchDescriptor<SDChatMessage>(
                predicate: #Predicate { $0.channel == channelName && $0.messageTypeRaw == "CHAT" && $0.text != "" },
                sortBy: [SortDescriptor(\.timestamp, order: .forward)]
            )
            if let saved = try? SwiftDataService.shared.context.fetch(descriptor) {
                self.chatMessages = saved.map { item in
                    Message(
                        id: item.id,
                        originID: item.originID.isEmpty ? item.channel : item.originID,
                        destinationID: item.destinationID.isEmpty ? item.channel : item.destinationID,
                        senderID: item.senderID.isEmpty ? item.channel : item.senderID,
                        senderName: item.senderName,
                        text: item.text,
                        timestamp: item.timestamp,
                        latitude: item.latitude,
                        longitude: item.longitude,
                        altitude: item.altitude,
                        accuracy: item.accuracy,
                        isSOS: false,
                        emergencyStatus: .normal,
                        hopsCount: 0,
                        conversationID: item.conversationID,
                        relayHistory: item.relayHistory.compactMap { UUID(uuidString: $0) },
                        isRead: item.isRead
                    )
                }
            }
        }
    }
    
    func loadVoiceMessages() {
        self.voiceMessages = SwiftDataService.shared.fetchVoiceMessages(for: selectedChannel)
    }
    
    func loadSwiftDataTranscripts() {
        let saved = SwiftDataService.shared.fetchTranscripts(for: selectedChannel)
        for item in saved {
            if !transcriptHistory.contains(where: { $0.id == item.id }) {
                transcriptHistory.append(item)
            }
        }
    }

    
    func createChannel(named name: String, passphrase: String? = nil) {
        guard FeatureAccessManager.shared.canAccess(.createChannel) else {
            AppLogger.multipeer.warning("Custom channel creation blocked: Relyvo Pro subscription required.")
            FeatureAccessManager.shared.presentPaywall(for: .createChannel)
            return
        }
        
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
        
        if let passphrase = passphrase, !passphrase.isEmpty {
            let success = ChannelKeyStore.shared.setKey(passphrase: passphrase, for: channelName)
            if success {
                AppLogger.multipeer.info("Created encrypted channel \(channelName)")
            } else {
                AppLogger.multipeer.error("Failed to derive key for channel \(channelName)")
            }
        }
        
        selectedChannel = channelName
        multipeerService.broadcastChannelSync(channelName: channelName)
        loadChannelMessages(for: channelName)
        HapticManager.successFeedback()
        AppLogger.multipeer.info("""
        [PINGLY_CHANNEL_CREATE]
        action=CREATE_CHANNEL
        channelID=\(channelName)
        isEncrypted=\(passphrase != nil && !passphrase!.isEmpty)
        """)
    }
    
    func tuneToEmergencyChannel() {
        self.selectedChannel = "CH-1 EMERGENCY"
        self.activeSOSAlert = nil
        HapticManager.successFeedback()
        AppLogger.multipeer.warning("[CHANNEL_SWITCH] Tuned directly to CH-1 EMERGENCY via SOS quick-action")
    }
    
    func dismissSOSAlert() {
        self.activeSOSAlert = nil
    }
    
    func triggerEmergencySOSBeacon(notes: String? = nil) {
        multipeerService.broadcastEmergencySOS(location: currentLocation, notes: notes)
        HapticManager.errorFeedback()
    }
    
    func sendChannelTextMessage(_ text: String) {
        guard FeatureAccessManager.shared.canAccess(.messaging) else {
            AppLogger.multipeer.warning("Message drop blocked: Relyvo Pro subscription required.")
            FeatureAccessManager.shared.presentPaywall(for: .messaging)
            return
        }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let localNodeID = NodeIdentity.shared.nodeID
        let handle = localUserHandle
        
        let newMessage = Message(
            originID: localNodeID,
            destinationID: "BROADCAST",
            senderID: localNodeID,
            senderName: handle,
            channelID: selectedChannel,
            text: trimmed,
            timestamp: Date(),
            latitude: currentLocation?.coordinate.latitude,
            longitude: currentLocation?.coordinate.longitude,
            isSOS: false,
            emergencyStatus: .normal,
            hopsCount: 0
        )
        
        chatMessages.append(newMessage)
        Task {
            await SwiftDataService.shared.persistenceActor.saveChatMessage(
                id: newMessage.id,
                originID: localNodeID,
                senderID: localNodeID,
                destinationID: "BROADCAST",
                senderName: handle,
                channel: selectedChannel,
                text: trimmed,
                timestamp: newMessage.timestamp,
                messageTypeRaw: "CHAT",
                latitude: currentLocation?.coordinate.latitude,
                longitude: currentLocation?.coordinate.longitude,
                conversationID: newMessage.conversationID
            )
        }
        multipeerService.broadcast(message: newMessage)
        messageText = ""
        HapticManager.lightImpact()
    }
    
    func triggerEmergencySOS(status: EmergencyStatus) {
        let localNodeID = NodeIdentity.shared.nodeID
        let handle = localUserHandle
        let location = self.currentLocation
        
        let sosText = "🚨 EMERGENCY DISTRESS BEACON: Need immediate assistance! Status: \(status.rawValue)"
        let sosMessage = Message(
            originID: localNodeID,
            destinationID: "BROADCAST",
            senderID: localNodeID,
            senderName: handle,
            channelID: "CH-1 EMERGENCY",
            text: sosText,
            timestamp: Date(),
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            isSOS: true,
            emergencyStatus: status,
            hopsCount: 0
        )
        
        if selectedChannel == "CH-1 EMERGENCY" {
            chatMessages.append(sosMessage)
        }
        
        Task {
            await SwiftDataService.shared.persistenceActor.saveChatMessage(
                id: sosMessage.id,
                originID: localNodeID,
                senderID: localNodeID,
                destinationID: "BROADCAST",
                senderName: handle,
                channel: "CH-1 EMERGENCY",
                text: sosText,
                timestamp: sosMessage.timestamp,
                messageTypeRaw: "CHAT",
                conversationID: sosMessage.conversationID
            )
        }
        multipeerService.broadcast(message: sosMessage)
        HapticManager.warningFeedback()
        self.activeSOSAlert = nil
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
        
        // Listen for incoming Emergency SOS beacons
        NotificationCenter.default.publisher(for: .didReceiveEmergencySOS)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notif in
                guard let self = self, let msg = notif.userInfo?["message"] as? Message else { return }
                let alert = SOSAlertPayload(
                    id: msg.id,
                    senderID: msg.senderID,
                    senderAlias: msg.senderName,
                    timestamp: msg.timestamp,
                    latitude: msg.latitude,
                    longitude: msg.longitude,
                    altitude: msg.altitude,
                    accuracy: msg.accuracy,
                    channelID: msg.channelID ?? "CH-1 EMERGENCY",
                    text: msg.text
                )
                self.activeSOSAlert = alert
                let distBearing = alert.distanceAndBearing(from: self.currentLocation)
                let distStr = distBearing?.distanceString ?? "unknown"
                let bearingStr = distBearing?.bearingString ?? "unknown"
                AppLogger.multipeer.info("""
                [DIAG_LOC_RX]
                originNode=\(msg.senderID)
                senderAlias=\(msg.senderName)
                parsedCoords=(\(msg.latitude ?? 0), \(msg.longitude ?? 0))
                distanceMeters=\(distStr)
                bearing=\(bearingStr)
                timestamp=\(msg.timestamp)
                """)
                HapticManager.errorFeedback()
                AppLogger.multipeer.warning("[SOS_VIEWMODEL_INGEST] Active SOS beacon registered from \(msg.senderName)")
            }
            .store(in: &cancellables)
            
        // Listen for newly saved voice messages to update channel timeline
        NotificationCenter.default.publisher(for: .didSaveVoiceMessage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.loadVoiceMessages()
                if !self.showingChatDrawer {
                    self.hasUnreadChannelMessages = true
                }
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
                if !self.showingChatDrawer {
                    self.hasUnreadChannelMessages = true
                }
            }
            .store(in: &cancellables)
            
        // Refresh UI state when keys are purged from in-memory cache
        NotificationCenter.default.publisher(for: .didPurgeChannelKeys)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        // Subscribe to incoming mesh text messages
        multipeerService.receivedMessagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self = self else { return }
                // Deduplicate and filter by active channel
                let isChannelMessage = message.channelID != nil && !message.channelID!.isEmpty && message.channelID!.hasPrefix("CH-")
                if isChannelMessage && message.channelID == self.selectedChannel {
                    if message.type == .chat && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !self.chatMessages.contains(where: { $0.id == message.id }) {
                            self.chatMessages.append(message)
                            if !self.showingChatDrawer {
                                self.hasUnreadChannelMessages = true
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)



        
        // Observe WalkieTalkieNetworkManager floor locks
        networkManager.$isFloorLockedBySelf
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLocked in
                guard let self = self else { return }
                self.isPTTPressed = isLocked
                self.session.isBroadcasting = isLocked
                if isLocked {
                    if self.sessionState != .handsFree {
                        self.sessionState = .transmitting
                    }
                } else if self.sessionState == .transmitting || self.sessionState == .handsFree {
                    self.sessionState = self.isConnected ? .idle : .outOfRange
                }
            }
            .store(in: &cancellables)
        
        networkManager.$activeFloorSenderID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] senderID in
                guard let self = self else { return }
                if let senderID = senderID, senderID != "LOCAL_SELF" {
                    let speaker = self.connectedPeerName.isEmpty || self.connectedPeerName == "Searching for Peers..." ? "Remote Peer" : self.connectedPeerName
                    self.liveActiveSpeaker = speaker
                    self.session.isReceivingAudio = true
                    self.session.activeSpeakerName = speaker
                    self.sessionState = .receiving(from: speaker)
                } else {
                    self.liveActiveSpeaker = nil
                    self.session.isReceivingAudio = false
                    self.session.activeSpeakerName = nil
                    if case .receiving = self.sessionState {
                        self.sessionState = self.isConnected ? .idle : .outOfRange
                    }
                }
            }
            .store(in: &cancellables)
        
        // Dynamic audio level updates for PTT waveform visualizer from real AudioStreamEngine
        AudioStreamEngine.shared.$currentAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.session.audioLevel = level
            }
            .store(in: &cancellables)
        
        // Channel presence tuned-in members binding
        ChannelPresenceManager.shared.$activeChannelMembers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] members in
                self?.activeChannelMembers = members
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
                    if self.sessionState == .outOfRange {
                        self.sessionState = .idle
                    }
                    
                    // Mark pending offline transcripts as delivered (GREEN) when peers join channel
                    Task {
                        await SwiftDataService.shared.persistenceActor.markTranscriptsAsDelivered(for: self.selectedChannel)
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .didSaveVoiceTranscript, object: nil)
                        }
                    }
                } else {
                    self.connectedPeerName = "Searching for Peers..."
                    self.connectedPeerRSSI = 0
                    self.isConnected = false
                    if self.sessionState != .transmitting && self.sessionState != .handsFree {
                        self.sessionState = .outOfRange
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    func toggleAddedToMessages() {
        isAddedToMessages.toggle()
        HapticManager.successFeedback()
    }
    
    func disconnect() {
        if isPTTPressed || sessionState == .transmitting || sessionState == .handsFree {
            stopTransmittingVoice()
        }
        isConnected = false
        sessionState = .outOfRange
        multipeerService.stopAdvertisingAndBrowsing()
        HapticManager.warningFeedback()
    }
    
    func startTransmittingVoice(handsFree: Bool = false) {
        guard FeatureAccessManager.shared.canAccess(.walkieTalkie) else {
            AppLogger.multipeer.warning("[PTT_DIAG][RadioCallViewModel] ❌ startTransmittingVoice BLOCKED by feature access (paywall)")
            FeatureAccessManager.shared.presentPaywall(for: .walkieTalkie)
            return
        }
        
        AppLogger.multipeer.info("[PTT_DIAG][RadioCallViewModel] 🎙️ startTransmittingVoice(handsFree=\(handsFree)) currentState=\(String(describing: self.sessionState)) isConnected=\(self.isConnected) peerCount=\(self.session.connectedPeersCount)")
        
        let handle = localUserHandle
        session.activeSpeakerName = handle
        let acquired = networkManager.acquireFloor()
        AppLogger.multipeer.info("[PTT_DIAG][RadioCallViewModel] acquireFloor() returned: \(acquired)")
        if acquired {
            sessionState = handsFree ? .handsFree : .transmitting
            HapticManager.mediumImpact()
        } else {
            AppLogger.multipeer.warning("[PTT_DIAG][RadioCallViewModel] ❌ Floor acquisition FAILED")
            HapticManager.warningFeedback()
        }
    }

    func stopTransmittingVoice() {
        AppLogger.multipeer.info("[PTT_DIAG][RadioCallViewModel] ⏹️ stopTransmittingVoice() currentState=\(String(describing: self.sessionState))")
        networkManager.releaseFloor()
        session.activeSpeakerName = nil
        sessionState = isConnected ? .idle : .outOfRange
        HapticManager.lightImpact()
    }
}




