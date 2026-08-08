//
//  MessagesViewModel.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import Combine
import CoreLocation
import os

struct Conversation: Identifiable, Hashable {
    let id: String
    let displayName: String
    let isOnline: Bool
    let lastMessage: String
    let lastTimestamp: String
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
    }
    
    func sendMessageToConversation(_ text: String, in conversation: Conversation) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            isSOS: false,
            emergencyStatus: .normal,
            hopsCount: 0
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
        
        multipeerService.broadcast(message: newMessage)
        messageText = ""
        HapticManager.lightImpact()
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
        if !messages.contains(where: { $0.id == message.id }) {
            var relayedMessage = message
            relayedMessage.hopsCount += 1
            messages.append(relayedMessage)
            
            // Relayed to matching conversation if applicable
            if let index = conversations.firstIndex(where: { $0.displayName == message.senderName }) {
                conversations[index].messages.append(relayedMessage)
            }
            
            _ = SwiftDataService.shared.saveChatMessage(senderName: message.senderName, channel: message.senderName, text: message.text)
            
            if relayedMessage.hopsCount <= Constants.Emergency.broadcastTTL {
                multipeerService.broadcast(message: relayedMessage)
            }
        }
    }

    
    private func loadSwiftDataConversations() {
        let saved = SwiftDataService.shared.fetchChatMessages(for: "GENERAL MESH")
        if !saved.isEmpty {
            let chatMessages = saved.map { item in
                Message(
                    id: item.id,
                    senderID: item.senderName,
                    senderName: item.senderName,
                    text: item.text,
                    timestamp: item.timestamp,
                    hopsCount: 0
                )
            }
            self.messages = chatMessages
        } else {
            self.conversations = []
            self.messages = []
        }
    }
}


