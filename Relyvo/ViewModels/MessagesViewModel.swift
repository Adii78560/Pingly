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
        
        // Channels are strictly managed by the Walkie-Talkie UI layer (RadioCallViewModel).
        // No public predefined channels are instantiated here.
        
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
            
        NotificationCenter.default.publisher(for: .didBecomeFriend)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self = self,
                      let nodeID = note.userInfo?["nodeID"] as? String else { return }
                
                Task {
                    let descriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == nodeID })
                    let handle = (try? SwiftDataService.shared.context.fetch(descriptor))?.first?.handle ?? "Unknown"
                    
                    await MainActor.run {
                        self.addPeerConversation(peerName: handle, nodeID: nodeID, channelName: "Direct")
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    func addPeerConversation(peerName: String, nodeID: String, channelName: String = "CH-1 EMERGENCY") {
        // 🔒 Communication Authorization Gate
        if !DirectChatGate.shared.canSendDirectMessage(to: nodeID) {
            AppLogger.multipeer.warning("Blocked auto-creation of direct conversation for unauthorized peer: \(nodeID)")
            return
        }
        
        _ = getOrCreateConversation(peerName: peerName, nodeID: nodeID, initialMessage: "Off-grid conversation on \(channelName)")
        AppLogger.multipeer.info("Added user '\(peerName)' (NodeID: \(nodeID)) on channel '\(channelName)' to Messages directory")
    }

    @discardableResult
    func getOrCreateConversation(peerName: String, nodeID: String, initialMessage: String = "Direct message thread") -> Conversation {
        let localNodeID = NodeIdentity.shared.nodeID
        let convID = DirectConversationID.make(nodeA: localNodeID, nodeB: nodeID).uuidString
        if let existing = conversations.first(where: { $0.id == convID }) {
            return existing
        }
        let isOnline = multipeerService.connectedPeers.contains(where: { $0.id == nodeID })
        let newConv = Conversation(
            id: convID,
            displayName: peerName,
            recipientNodeID: nodeID,
            isOnline: isOnline,
            lastMessage: initialMessage,
            lastTimestamp: Date().logTimeString,
            messages: []
        )
        conversations.append(newConv)
        return newConv
    }
    

    
    func sendMessageToConversation(_ text: String, in conversation: Conversation) {
        guard FeatureAccessManager.shared.canAccess(.messaging) else {
            AppLogger.multipeer.warning("Messaging blocked: Relyvo Pro subscription required.")
            FeatureAccessManager.shared.presentPaywall(for: .messaging)
            return
        }
        
        // 🔒 Communication Authorization Gate
        if !DirectChatGate.shared.canSendDirectMessage(to: conversation.recipientNodeID) {
            AppLogger.multipeer.warning("Blocked outgoing direct CHAT packet to unauthorized recipient: \(conversation.recipientNodeID)")
            return
        }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let localNodeID = NodeIdentity.shared.nodeID
        let handle = NodeIdentity.shared.displayName
        let location = locationService.currentLocation
        
        let isChannel = conversation.displayName.hasPrefix("CH-")
        let destination = isChannel ? "BROADCAST" : conversation.recipientNodeID
        let channel = isChannel ? conversation.displayName : nil
        
        let newMessage = Message(
            originID: localNodeID,
            destinationID: destination,
            senderID: localNodeID,
            senderName: handle,
            channelID: channel,
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
                timestamp: newMessage.timestamp,
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
                let isBroadcastOrChannel = (newMessage.destinationID == "BROADCAST") || (newMessage.channelID?.hasPrefix("CH-") == true)
                if isBroadcastOrChannel {
                    await SwiftDataService.shared.persistenceActor.deletePendingMessage(messageID: newMessage.id)
                    AppLogger.multipeer.info("Broadcasted P2P message \(newMessage.id) for '\(conversation.displayName)' without ACK tracking.")
                } else {
                    await SwiftDataService.shared.persistenceActor.updatePendingMessageStatus(messageID: newMessage.id, statusRaw: "WAITING_FOR_ACK")
                    AppLogger.multipeer.info("Broadcasted P2P message \(newMessage.id) for '\(conversation.displayName)' (waiting for ACK).")
                }
            }
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
                    timestamp: newMessage.timestamp,
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

    
    func markConversationAsRead(conversationID: String) {
        if let idx = self.conversations.firstIndex(where: { $0.id == conversationID }) {
            for i in 0..<self.conversations[idx].messages.count {
                self.conversations[idx].messages[i].isRead = true
            }
        }
        
        guard let uuid = UUID(uuidString: conversationID) else { return }
        Task {
            await SwiftDataService.shared.persistenceActor.markConversationAsRead(conversationID: uuid)
        }
    }
    private func cleanBaseName(_ name: String) -> String {
        return name.replacingOccurrences(of: #"_([A-Fa-f0-9]{4}_[A-Fa-f0-9]{4}|\d{4}|[A-Fa-f0-9]{8})$"#, with: "", options: .regularExpression)
                   .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    

    

    
    private func handleIncomingMessage(_ message: Message) {
        let localNodeID = NodeIdentity.shared.nodeID
        guard message.originID != localNodeID else { return } // Avoid self-echo
        guard message.type == .chat || message.type == .location || message.type == .transcript else { return }
        
        let isChannelMessage = message.channelID != nil && !message.channelID!.isEmpty && message.channelID!.hasPrefix("CH-")
        if isChannelMessage {
            // MultipeerService handles background persistence globally for channel messages.
            // We exit early here to ensure Channels NEVER generate a Messages-tab conversation card.
            return
        }
        
        var relayedMessage = message
        relayedMessage.hopsCount += 1
        
        if !messages.contains(where: { $0.id == message.id }) {
            messages.append(relayedMessage)
        }
        
        let senderNodeID = message.originID
        let convID = message.conversationID.uuidString
        let convName = message.senderName
        let convRecipient = senderNodeID
        
        // NOTE: We intentionally do NOT gate incoming direct messages on friendship status.
        // MultipeerService already persists all incoming messages to SwiftData; blocking the
        // UI here (but not the DB write) created a session-vs-reload inconsistency where
        // received messages were invisible during the session but appeared after a restart.
        // Sending is still gated via DirectChatGate in sendMessageToConversation.
        
        if selectedConversation?.id == convID {
            relayedMessage.isRead = true
        } else {
            relayedMessage.isRead = false
        }
        
        // Find existing conversation or AUTOMATICALLY create conversation card
        if let index = conversations.firstIndex(where: { $0.id == convID }) {
            if !conversations[index].messages.contains(where: { $0.id == message.id }) {
                conversations[index].messages.append(relayedMessage)
            }
            conversations[index].lastMessage = message.text
            conversations[index].lastTimestamp = message.timestamp.logTimeString
            conversations[index].isOnline = true
            
            // Explicitly sync the selected conversation if the user is currently viewing it
            if selectedConversation?.id == convID {
                selectedConversation = conversations[index]
            }
        } else {
            let newConv = Conversation(
                id: convID,
                displayName: convName,
                recipientNodeID: convRecipient,
                isOnline: true,
                lastMessage: message.text,
                lastTimestamp: message.timestamp.logTimeString,
                messages: [relayedMessage]
            )
            conversations.append(newConv)
            AppLogger.multipeer.info("Auto-created conversation thread for incoming peer/channel: \(convName) (ConvID: \(convID))")
        }
        
        // NOTE: Persistence for incoming messages is handled exclusively by MultipeerService
        // (saveChatMessage with isDelivered: true + correct conversationID). Persisting here
        // as well caused a double-write race where messageTypeRaw was non-deterministic.
        
        if relayedMessage.hopsCount <= Constants.Emergency.broadcastTTL {
            multipeerService.broadcast(message: relayedMessage)
        }
    }

    
    private func loadSwiftDataConversations() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let chatPredicate = #Predicate<SDChatMessage> { msg in
                (msg.messageTypeRaw == "CHAT" || msg.messageTypeRaw == "TEXT") &&
                !msg.text.contains("LOCATION_PROTOCOL:")
            }
            let descriptor = FetchDescriptor<SDChatMessage>(predicate: chatPredicate, sortBy: [SortDescriptor(\.timestamp, order: .forward)])
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
                        relayHistory: item.relayHistory.compactMap { UUID(uuidString: $0) },
                        isRead: item.isRead
                    )
                    grouped[item.conversationID.uuidString, default: []].append(msg)
                }
                
                for (convID, msgList) in grouped {
                    if let last = msgList.last {
                        // Try to find the remote peer's name from a received message first.
                        // If all messages are outgoing (no replies yet), fall back to the
                        // SDFriend record so the conversation card shows the recipient's name
                        // instead of the local user's name.
                        let localNodeID = NodeIdentity.shared.nodeID
                        let localDisplayName = NodeIdentity.shared.displayName
                        
                        let peerName: String
                        if let incomingMsg = msgList.first(where: { $0.senderID != localNodeID && $0.senderName != localDisplayName }) {
                            peerName = incomingMsg.senderName
                        } else {
                            // All outgoing — look up recipient in SDFriend by destinationID.
                            let recipientCandidate = last.destinationID
                            let friendDescriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == recipientCandidate })
                            peerName = (try? SwiftDataService.shared.context.fetch(friendDescriptor))?.first?.handle ?? last.senderName
                        }
                        
                        let recipientNodeID = msgList.first(where: { $0.senderID != localNodeID })?.senderID ?? last.destinationID
                        
                        AppLogger.multipeer.info("[MESSAGE_LOADED] convID=\(convID) messageCount=\(msgList.count) peer=\(peerName)")
                        
                        if let idx = self.conversations.firstIndex(where: { $0.id == convID }) {
                            self.conversations[idx].messages = msgList
                            self.conversations[idx].lastMessage = last.text
                            self.conversations[idx].lastTimestamp = last.timestamp.logTimeString
                        } else {
                            let conv = Conversation(
                                id: convID,
                                displayName: peerName,
                                recipientNodeID: recipientNodeID,
                                isOnline: self.multipeerService.connectedPeers.contains(where: { $0.id == recipientNodeID }),
                                lastMessage: last.text,
                                lastTimestamp: last.timestamp.logTimeString,
                                messages: msgList
                            )
                            self.conversations.append(conv)
                        }
                    }
                }
            }
        }
    }
}



