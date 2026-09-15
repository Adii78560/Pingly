//
//  MessagesViewModel.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import Combine
import CoreLocation
import SwiftData
import os

struct Conversation: Identifiable, Hashable {
    let id: String
    let displayName: String
    let recipientNodeID: String
    var isOnline: Bool
    var lastMessage: String
    var lastTimestamp: String
    var messages: [Message]
}


/// View model driving the Offline Messages & Chat Directory
final class MessagesViewModel: ObservableObject {
    
    @Published var conversations: [Conversation] = []
    @Published var selectedConversation: Conversation?
    @Published var messages: [Message] = []
    @Published var messageText: String = ""
    @Published var isSOSAlertActive: Bool = false
    @Published var activeEmergencyStatus: EmergencyStatus = .normal
    
    private let multipeerService: MultipeerService
    private let locationService: LocationService
    private var cancellables = Set<AnyCancellable>()
    
    init(multipeerService: MultipeerService, locationService: LocationService) {
        self.multipeerService = multipeerService
        self.locationService = locationService
        setupSubscriptions()
        loadSwiftDataConversations()
    }

    
    private func setupSubscriptions() {
        multipeerService.receivedMessagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleIncomingMessage(message)
            }
            .store(in: &cancellables)
            
        NotificationCenter.default.publisher(for: .didAddPeerToMessages)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self = self,
                      let peerName = note.userInfo?["peerName"] as? String,
                      let nodeID = note.userInfo?["nodeID"] as? String else { return }
                let channelName = (note.userInfo?["channel"] as? String) ?? "CH-1 EMERGENCY"
                self.addPeerConversation(peerName: peerName, nodeID: nodeID, channelName: channelName)
            }
            .store(in: &cancellables)
    }
    
    func addPeerConversation(peerName: String, nodeID: String, channelName: String = "CH-1 EMERGENCY") {
        let localNodeID = NodeIdentity.shared.nodeID
        let convID = DirectConversationID.make(nodeA: localNodeID, nodeB: nodeID).uuidString
        if !conversations.contains(where: { $0.id == convID }) {
            let newConv = Conversation(
                id: convID,
                displayName: peerName,
                recipientNodeID: nodeID,
                isOnline: multipeerService.connectedPeers.contains(where: { $0.id == nodeID }),
                lastMessage: "Off-grid conversation on \(channelName)",
                lastTimestamp: Date().logTimeString,
                messages: []
            )
            conversations.append(newConv)
            AppLogger.multipeer.info("Added user '\(peerName)' (NodeID: \(nodeID)) on channel '\(channelName)' to Messages directory")
        }
    }

    
    func sendMessageToConversation(_ text: String, in conversation: Conversation) {
        guard FeatureAccessManager.shared.canAccess(.messaging) else {
            AppLogger.multipeer.warning("Messaging blocked: Relyvo Pro subscription required.")
            FeatureAccessManager.shared.presentPaywall(for: .messaging)
            return
        }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let localNodeID = NodeIdentity.shared.nodeID
        let handle = NodeIdentity.shared.displayName
        let location = locationService.currentLocation
        
        let newMessage = Message(
            originID: localNodeID,
            destinationID: conversation.recipientNodeID,
            senderID: localNodeID,
            senderName: handle,
            channelID: nil,
            text: trimmed,
            timestamp: Date(),
            latitude: location?.latitude,
            longitude: location?.longitude,
            isSOS: false,
            emergencyStatus: .normal,
            hopsCount: 0,
            type: .chat
        )
        
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].messages.append(newMessage)
            let updated = Conversation(
                id: conversations[index].id,
                displayName: conversations[index].displayName,
                recipientNodeID: conversations[index].recipientNodeID,
                isOnline: conversations[index].isOnline,
                lastMessage: trimmed,
                lastTimestamp: Date().logTimeString,
                messages: conversations[index].messages
            )
            conversations[index] = updated
            if selectedConversation?.id == conversation.id {
                selectedConversation = updated
            }
        }
        
        // Persist message to SwiftData local storage
        Task {
            await SwiftDataService.shared.persistenceActor.saveChatMessage(
                id: newMessage.id,
                originID: localNodeID,
                senderID: localNodeID,
                destinationID: conversation.recipientNodeID,
                senderName: handle,
                channel: conversation.recipientNodeID,
                text: trimmed,
                messageTypeRaw: "CHAT",
                conversationID: newMessage.conversationID
            )
        }
        
        // Enqueue in persistent store-and-forward queue with WAITING_FOR_ACK / QUEUED state
        Task {
            await SwiftDataService.shared.persistenceActor.enqueuePendingMessage(
                messageID: newMessage.id,
                originID: localNodeID,
                destinationID: conversation.recipientNodeID,
                recipientName: conversation.displayName,
                senderName: handle,
                text: trimmed,
                channel: conversation.recipientNodeID,
                isSOS: false,
                priorityRaw: 0,
                statusRaw: "QUEUED",
                queueRoleRaw: "ORIGIN",
                hopsCount: 0,
                ttl: Constants.Emergency.broadcastTTL
            )
        }

        
        if !multipeerService.connectedPeers.isEmpty {
            multipeerService.broadcast(message: newMessage)
            Task {
                await SwiftDataService.shared.persistenceActor.updatePendingMessageStatus(messageID: newMessage.id, statusRaw: "WAITING_FOR_ACK")
            }
            AppLogger.multipeer.info("Broadcasted P2P message \(newMessage.id) for '\(conversation.displayName)' (waiting for ACK).")
        } else {
            AppLogger.multipeer.info("Peer '\(conversation.displayName)' is offline. Enqueued message \(newMessage.id) to store-and-forward queue.")
        }

        
        messageText = ""
        HapticManager.lightImpact()
    }
    
    /// Obtains current offline GPS coordinates and sends location message over P2P mesh
    func sendLocationMessage(in conversation: Conversation) {
        guard FeatureAccessManager.shared.canAccess(.messaging) else {
            AppLogger.multipeer.warning("Location messaging blocked: Relyvo Pro subscription required.")
            FeatureAccessManager.shared.presentPaywall(for: .messaging)
            return
        }
        
        LocationService.shared.getCurrentLocationSnapshot { [weak self] location in
            guard let self = self, let loc = location else {
                LocationService.shared.requestLocationPermission()
                return
            }
            
            let handle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
            let localNodeID = NodeIdentity.shared.nodeID
            
            let locationText = String(format: "📍 Shared Location: %.4f° N, %.4f° E", loc.coordinate.latitude, loc.coordinate.longitude)
            
            let newMessage = Message(
                originID: localNodeID,
                destinationID: conversation.recipientNodeID,
                senderID: localNodeID,
                senderName: handle,
                channelID: nil,
                text: locationText,
                timestamp: Date(),
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                altitude: loc.altitude,
                accuracy: loc.horizontalAccuracy,
                type: .location
            )
            
            DispatchQueue.main.async {
                self.messages.append(newMessage)
                if let index = self.conversations.firstIndex(where: { $0.id == conversation.id }) {
                    self.conversations[index].messages.append(newMessage)
                    self.conversations[index].lastMessage = "📍 Shared Location"
                    self.conversations[index].lastTimestamp = Date().logTimeString

                }
            }
            
            Task {
                await SwiftDataService.shared.persistenceActor.saveChatMessage(
                    id: newMessage.id,
                    originID: localNodeID,
                    senderID: localNodeID,
                    destinationID: conversation.recipientNodeID,
                    senderName: handle,
                    channel: conversation.recipientNodeID,
                    text: locationText,
                    messageTypeRaw: "LOCATION",
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    altitude: loc.altitude,
                    accuracy: loc.horizontalAccuracy
                )
            }
            
            Task {
                await SwiftDataService.shared.persistenceActor.enqueuePendingMessage(
                    messageID: newMessage.id,
                    originID: localNodeID,
                    destinationID: conversation.recipientNodeID,
                    recipientName: conversation.displayName,
                    senderName: handle,
                    text: locationText,
                    channel: conversation.recipientNodeID,
                    isSOS: false,
                    priorityRaw: 0,
                    statusRaw: "QUEUED",
                    queueRoleRaw: "ORIGIN",
                    hopsCount: 0,
                    ttl: Constants.Emergency.broadcastTTL
                )
            }
            
            if !self.multipeerService.connectedPeers.isEmpty {
                self.multipeerService.broadcast(message: newMessage)
            }
            
            HapticManager.successFeedback()
        }
    }

    
    private func cleanBaseName(_ name: String) -> String {
        return name.replacingOccurrences(of: #"_([A-Fa-f0-9]{4}_[A-Fa-f0-9]{4}|\d{4}|[A-Fa-f0-9]{8})$"#, with: "", options: .regularExpression)
                   .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    
    func sendMessageDrop() {
        guard FeatureAccessManager.shared.canAccess(.messaging) else {
            AppLogger.multipeer.warning("Message drop blocked: Relyvo Pro subscription required.")
            FeatureAccessManager.shared.presentPaywall(for: .messaging)
            return
        }
        
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let localNodeID = NodeIdentity.shared.nodeID
        let handle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        let location = locationService.currentLocation
        
        let newMessage = Message(
            originID: localNodeID,
            destinationID: "BROADCAST",
            senderID: localNodeID,
            senderName: handle,
            channelID: "CH-1 EMERGENCY",
            text: trimmed,
            timestamp: Date(),
            latitude: location?.latitude,
            longitude: location?.longitude,
            isSOS: isSOSAlertActive,
            emergencyStatus: activeEmergencyStatus,
            hopsCount: 0
        )
        
        messages.append(newMessage)
        Task {
            await SwiftDataService.shared.persistenceActor.saveChatMessage(
                id: newMessage.id,
                senderID: localNodeID,
                senderName: handle,
                channel: "CH-1 EMERGENCY",
                text: trimmed,
                messageTypeRaw: "CHAT"
            )
        }
        multipeerService.broadcast(message: newMessage)
        messageText = ""
        HapticManager.lightImpact()
    }
    
    func triggerEmergencySOS(status: EmergencyStatus) {
        self.activeEmergencyStatus = status
        self.isSOSAlertActive = true
        
        let localNodeID = NodeIdentity.shared.nodeID
        let handle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        let location = locationService.currentLocation
        
        let sosText = "🚨 EMERGENCY DISTRESS BEACON: Need immediate assistance! Status: \(status.rawValue)"
        let sosMessage = Message(
            originID: localNodeID,
            destinationID: "BROADCAST",
            senderID: localNodeID,
            senderName: handle,
            channelID: "CH-1 EMERGENCY",
            text: sosText,
            timestamp: Date(),
            latitude: location?.latitude,
            longitude: location?.longitude,
            isSOS: true,
            emergencyStatus: status,
            hopsCount: 0
        )
        
        messages.append(sosMessage)
        Task {
            await SwiftDataService.shared.persistenceActor.saveChatMessage(
                id: sosMessage.id,
                senderID: localNodeID,
                senderName: handle,
                channel: "CH-1 EMERGENCY",
                text: sosText,
                messageTypeRaw: "CHAT"
            )
        }
        multipeerService.broadcast(message: sosMessage)
        HapticManager.warningFeedback()
        AppLogger.emergency.critical("Triggered Emergency SOS Beacon with status: \(status.rawValue)")
    }
    
    private func handleIncomingMessage(_ message: Message) {
        let localNodeID = NodeIdentity.shared.nodeID
        guard message.originID != localNodeID else { return } // Avoid self-echo
        
        var relayedMessage = message
        relayedMessage.hopsCount += 1
        
        if !messages.contains(where: { $0.id == message.id }) {
            messages.append(relayedMessage)
        }
        
        let senderNodeID = message.originID
        let isChannelMessage = message.channelID != nil && !message.channelID!.isEmpty && message.channelID!.hasPrefix("CH-")
        
        if isChannelMessage {
            return
        }
        
        let convID = message.conversationID.uuidString
        
        // Find existing conversation or AUTOMATICALLY create conversation card
        if let index = conversations.firstIndex(where: { $0.id == convID }) {
            if !conversations[index].messages.contains(where: { $0.id == message.id }) {
                conversations[index].messages.append(relayedMessage)
            }
            conversations[index].lastMessage = message.text
            conversations[index].lastTimestamp = message.timestamp.logTimeString
            conversations[index].isOnline = true
        } else {
            let newConv = Conversation(
                id: convID,
                displayName: message.senderName,
                recipientNodeID: senderNodeID,
                isOnline: true,
                lastMessage: message.text,
                lastTimestamp: message.timestamp.logTimeString,
                messages: [relayedMessage]
            )
            conversations.append(newConv)
            AppLogger.multipeer.info("Auto-created conversation thread for incoming peer: \(message.senderName) (ConvID: \(convID))")
        }
        
        Task {
            await SwiftDataService.shared.persistenceActor.saveChatMessage(
                id: message.id,
                originID: message.originID,
                senderID: message.senderID,
                destinationID: message.destinationID,
                senderName: message.senderName,
                channel: senderNodeID,
                text: message.text,
                isDelivered: true,
                messageTypeRaw: "CHAT"
            )
        }
        
        if relayedMessage.hopsCount <= Constants.Emergency.broadcastTTL {
            multipeerService.broadcast(message: relayedMessage)
        }
    }

    
    private func loadSwiftDataConversations() {
        let descriptor = FetchDescriptor<SDChatMessage>(sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        if let saved = try? SwiftDataService.shared.context.fetch(descriptor) {
            var grouped: [String: [Message]] = [:]
            for item in saved {
                if item.channel.hasPrefix("CH-") || item.channel == "GENERAL MESH" || item.channel == "EMERGENCY BEACON" {
                    continue
                }
                
                let msg = Message(
                    id: item.id,
                    originID: item.originID.isEmpty ? item.channel : item.originID,
                    destinationID: item.destinationID.isEmpty ? item.channel : item.destinationID,
                    senderID: item.senderID.isEmpty ? item.channel : item.senderID,
                    senderName: item.senderName,
                    text: item.text,
                    timestamp: item.timestamp,
                    hopsCount: 0,
                    conversationID: item.conversationID,
                    relayHistory: item.relayHistory.compactMap { UUID(uuidString: $0) }
                )
                grouped[item.conversationID.uuidString, default: []].append(msg)
            }
            
            for (convID, msgList) in grouped {
                if let last = msgList.last {
                    let peerName = msgList.first(where: { $0.senderID != NodeIdentity.shared.nodeID && $0.senderName != NodeIdentity.shared.displayName })?.senderName ?? last.senderName
                    
                    let recipientNodeID = msgList.first(where: { $0.senderID != NodeIdentity.shared.nodeID })?.senderID ?? last.destinationID
                    
                    if let idx = conversations.firstIndex(where: { $0.id == convID }) {
                        conversations[idx].messages = msgList
                        conversations[idx].lastMessage = last.text
                        conversations[idx].lastTimestamp = last.timestamp.logTimeString
                    } else {
                        let conv = Conversation(
                            id: convID,
                            displayName: peerName,
                            recipientNodeID: recipientNodeID,
                            isOnline: multipeerService.connectedPeers.contains(where: { $0.id == recipientNodeID }),
                            lastMessage: last.text,
                            lastTimestamp: last.timestamp.logTimeString,
                            messages: msgList
                        )
                        conversations.append(conv)
                    }
                }
            }
        }
    }
}



