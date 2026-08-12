//
//  MessagesViewModel.swift
//  Pingly
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
                guard let self = self, let peerName = note.userInfo?["peerName"] as? String else { return }
                let channelName = (note.userInfo?["channel"] as? String) ?? "CH-1 EMERGENCY"
                self.addPeerConversation(peerName: peerName, channelName: channelName)
            }
            .store(in: &cancellables)
    }
    
    func addPeerConversation(peerName: String, channelName: String = "CH-1 EMERGENCY") {
        let convID = "\(peerName)_\(channelName)"
        if !conversations.contains(where: { $0.id == convID || ($0.displayName == peerName && $0.lastMessage.contains(channelName)) }) {
            let newConv = Conversation(
                id: convID,
                displayName: peerName,
                isOnline: multipeerService.connectedPeers.contains(where: { $0.displayName == peerName }),
                lastMessage: "Off-grid conversation on \(channelName)",
                lastTimestamp: Date().logTimeString,
                messages: []
            )
            conversations.append(newConv)
            AppLogger.multipeer.info("Added user '\(peerName)' on channel '\(channelName)' to Messages directory")
        }
    }

    
    func sendMessageToConversation(_ text: String, in conversation: Conversation) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let localNodeID = NodeIdentity.shared.nodeID
        let handle = NodeIdentity.shared.displayName
        let location = locationService.currentLocation
        
        let newMessage = Message(
            originID: localNodeID,
            destinationID: conversation.displayName,
            senderID: localNodeID,
            senderName: handle,
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
        _ = SwiftDataService.shared.saveChatMessage(senderName: handle, channel: conversation.displayName, text: trimmed)
        
        // Enqueue in persistent store-and-forward queue with WAITING_FOR_ACK / QUEUED state
        _ = SwiftDataService.shared.enqueuePendingMessage(
            messageID: newMessage.id,
            originID: localNodeID,
            destinationID: conversation.displayName,
            recipientName: conversation.displayName,
            senderName: handle,
            text: trimmed,
            channel: conversation.displayName
        )

        
        if !multipeerService.connectedPeers.isEmpty {
            multipeerService.broadcast(message: newMessage)
            SwiftDataService.shared.updatePendingMessageStatus(messageID: newMessage.id, status: .waitingForACK)
            AppLogger.multipeer.info("Broadcasted P2P message \(newMessage.id) for '\(conversation.displayName)' (waiting for ACK).")
        } else {
            AppLogger.multipeer.info("Peer '\(conversation.displayName)' is offline. Enqueued message \(newMessage.id) to store-and-forward queue.")
        }


        
        messageText = ""
        HapticManager.lightImpact()
    }
    
    /// Obtains current offline GPS coordinates and sends location message over P2P mesh
    func sendLocationMessage(in conversation: Conversation) {
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
                destinationID: conversation.displayName,
                senderID: localNodeID,
                senderName: handle,
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
            
            _ = SwiftDataService.shared.saveChatMessage(
                senderName: handle,
                channel: conversation.displayName,
                text: locationText,
                messageType: .location,
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                altitude: loc.altitude,
                accuracy: loc.horizontalAccuracy
            )
            
            _ = SwiftDataService.shared.enqueuePendingMessage(
                messageID: newMessage.id,
                originID: localNodeID,
                destinationID: conversation.displayName,
                recipientName: conversation.displayName,
                senderName: handle,
                text: locationText,
                channel: conversation.displayName
            )
            
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
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let handle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        let location = locationService.currentLocation
        
        let newMessage = Message(
            senderID: handle,
            senderName: handle,
            text: trimmed,
            timestamp: Date(),
            latitude: location?.latitude,
            longitude: location?.longitude,
            isSOS: isSOSAlertActive,
            emergencyStatus: activeEmergencyStatus,
            hopsCount: 0
        )
        
        messages.append(newMessage)
        _ = SwiftDataService.shared.saveChatMessage(senderName: handle, channel: "GENERAL MESH", text: trimmed)
        multipeerService.broadcast(message: newMessage)
        messageText = ""
        HapticManager.lightImpact()
    }
    
    func triggerEmergencySOS(status: EmergencyStatus) {
        self.activeEmergencyStatus = status
        self.isSOSAlertActive = true
        
        let handle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        let location = locationService.currentLocation
        
        let sosText = "🚨 EMERGENCY DISTRESS BEACON: Need immediate assistance! Status: \(status.rawValue)"
        let sosMessage = Message(
            senderID: handle,
            senderName: handle,
            text: sosText,
            timestamp: Date(),
            latitude: location?.latitude,
            longitude: location?.longitude,
            isSOS: true,
            emergencyStatus: status,
            hopsCount: 0
        )
        
        messages.append(sosMessage)
        _ = SwiftDataService.shared.saveChatMessage(senderName: handle, channel: "EMERGENCY BEACON", text: sosText)
        multipeerService.broadcast(message: sosMessage)
        HapticManager.warningFeedback()
        AppLogger.emergency.critical("Triggered Emergency SOS Beacon with status: \(status.rawValue)")
    }
    
    private func handleIncomingMessage(_ message: Message) {
        let cleanSender = cleanBaseName(message.senderName)
        let localUserHandle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        guard cleanSender != cleanBaseName(localUserHandle) else { return } // Avoid self-echo
        
        var relayedMessage = message
        relayedMessage.hopsCount += 1
        
        if !messages.contains(where: { $0.id == message.id }) {
            messages.append(relayedMessage)
        }
        
        // Find existing conversation or AUTOMATICALLY create conversation card for incoming sender
        if let index = conversations.firstIndex(where: { cleanBaseName($0.displayName) == cleanSender || $0.id.contains(cleanSender) }) {
            if !conversations[index].messages.contains(where: { $0.id == message.id }) {
                conversations[index].messages.append(relayedMessage)
            }
            conversations[index].lastMessage = message.text
            conversations[index].lastTimestamp = message.timestamp.logTimeString
            conversations[index].isOnline = true
        } else {
            let newConv = Conversation(
                id: "\(cleanSender)_AUTO",
                displayName: message.senderName,
                isOnline: true,
                lastMessage: message.text,
                lastTimestamp: message.timestamp.logTimeString,
                messages: [relayedMessage]
            )
            conversations.append(newConv)
            AppLogger.multipeer.info("Auto-created conversation thread for incoming peer: \(message.senderName)")
        }
        
        _ = SwiftDataService.shared.saveChatMessage(
            senderName: message.senderName,
            channel: message.senderName,
            text: message.text,
            isDelivered: true
        )
        
        if relayedMessage.hopsCount <= Constants.Emergency.broadcastTTL {
            multipeerService.broadcast(message: relayedMessage)
        }
    }

    
    private func loadSwiftDataConversations() {
        let descriptor = FetchDescriptor<SDChatMessage>(sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        if let saved = try? SwiftDataService.shared.context.fetch(descriptor) {
            var grouped: [String: [Message]] = [:]
            for item in saved {
                let msg = Message(
                    id: item.id,
                    senderID: item.senderName,
                    senderName: item.senderName,
                    text: item.text,
                    timestamp: item.timestamp,
                    hopsCount: 0
                )
                let base = cleanBaseName(item.senderName)
                grouped[base, default: []].append(msg)
            }
            
            for (senderBase, msgList) in grouped {
                if let last = msgList.last {
                    if let idx = conversations.firstIndex(where: { cleanBaseName($0.displayName) == senderBase }) {
                        conversations[idx].messages = msgList
                        conversations[idx].lastMessage = last.text
                        conversations[idx].lastTimestamp = last.timestamp.logTimeString
                    } else {
                        let conv = Conversation(
                            id: "\(senderBase)_SAVED",
                            displayName: last.senderName,
                            isOnline: multipeerService.connectedPeers.contains(where: { cleanBaseName($0.displayName) == senderBase }),
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



