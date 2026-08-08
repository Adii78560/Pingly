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

/// View model driving the Emergency Message Drop & Mesh Timeline screen
final class MessagesViewModel: ObservableObject {
    
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
        loadDemoSampleMessages()
    }
    
    private func setupSubscriptions() {
        multipeerService.receivedMessagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleIncomingMessage(message)
            }
            .store(in: &cancellables)
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
        multipeerService.broadcast(message: newMessage)
        messageText = ""
    }
    
    func triggerEmergencySOS(status: EmergencyStatus) {
        self.activeEmergencyStatus = status
        self.isSOSAlertActive = true
        
        let handle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        let location = locationService.currentLocation
        
        let sosMessage = Message(
            senderID: handle,
            senderName: handle,
            text: "🚨 EMERGENCY DISTRESS BEACON: Need immediate assistance! Status: \(status.rawValue)",
            timestamp: Date(),
            latitude: location?.latitude,
            longitude: location?.longitude,
            isSOS: true,
            emergencyStatus: status,
            hopsCount: 0
        )
        
        messages.append(sosMessage)
        multipeerService.broadcast(message: sosMessage)
        AppLogger.emergency.critical("Triggered Emergency SOS Beacon with status: \(status.rawValue)")
    }
    
    private func handleIncomingMessage(_ message: Message) {
        if !messages.contains(where: { $0.id == message.id }) {
            var relayedMessage = message
            relayedMessage.hopsCount += 1
            messages.append(relayedMessage)
            
            // Store and forward relay if TTL remaining
            if relayedMessage.hopsCount <= Constants.Emergency.broadcastTTL {
                multipeerService.broadcast(message: relayedMessage)
            }
        }
    }
    
    private func loadDemoSampleMessages() {
        let handle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        self.messages = [
            Message(
                senderID: "MeshNode_Alpha",
                senderName: "Alpha Search Team",
                text: "Pingly mesh active on CH-1. Mountain base camp signal verified.",
                timestamp: Date().addingTimeInterval(-300),
                latitude: 45.8326,
                longitude: 6.8652,
                isSOS: false,
                emergencyStatus: .normal
            ),
            Message(
                senderID: handle,
                senderName: handle,
                text: "Pingly node online. BLE & Wi-Fi Direct scanning enabled.",
                timestamp: Date().addingTimeInterval(-120),
                isSOS: false,
                emergencyStatus: .normal
            )
        ]
    }
}
