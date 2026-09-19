//
//  RadarViewModel.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import Combine

/// View model driving the Proximity Radar screen
final class RadarViewModel: ObservableObject {
    
    @Published var nearbyPeers: [PeerDevice] = []
    @Published var isScanning: Bool = true
    @Published var selectedPeer: PeerDevice?
    @Published var broadcastName: String
    @Published var isConnectingToPeer: Bool = false
    
    private let multipeerService: MultipeerService
    private let bleBeaconService: BLEBeaconService
    private var cancellables = Set<AnyCancellable>()
    
    init(multipeerService: MultipeerService, bleBeaconService: BLEBeaconService) {
        self.multipeerService = multipeerService
        self.bleBeaconService = bleBeaconService
        self.broadcastName = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        fetchFriends()
        setupBindings()
    }
    
    private func setupBindings() {
        Publishers.CombineLatest3(multipeerService.connectedPeersPublisher, multipeerService.discoveredPeersPublisher, bleBeaconService.$discoveredBLEPeers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (connectedPeers, discoveredPeers, blePeers) in
                guard let self = self else { return }
                var merged = [String: PeerDevice]() // Deduplicate strictly by canonical NodeID (id)
                
                // 1. Add BLE peers
                for var ble in blePeers {
                    ble.isConnected = false
                    merged[ble.id] = ble
                }
                
                // 2. Add Discovered peers via MultipeerConnectivity
                for var disc in discoveredPeers {
                    disc.isConnected = false
                    // Update if exists (Multipeer discovery typically has better context than raw BLE)
                    merged[disc.id] = disc
                }
                
                // 3. Overlay Connected peers (highest priority state)
                for var conn in connectedPeers {
                    conn.isConnected = true
                    merged[conn.id] = conn
                }
                
                // Sort by RSSI signal strength (strongest first)
                self.nearbyPeers = Array(merged.values).sorted(by: { $0.rssi > $1.rssi })
            }
            .store(in: &cancellables)
            
        NotificationCenter.default.publisher(for: .didUpdateFriends)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.fetchFriends()
            }
            .store(in: &cancellables)
    }
    
    private func cleanBaseName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"_\d{4}$"#, options: .regularExpression) {
            return String(trimmed[..<range.lowerBound]).lowercased()
        }
        return trimmed.lowercased()
    }


    
    func updateBroadcastName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.broadcastName = trimmed
        UserDefaults.standard.set(trimmed, forKey: Constants.StorageKeys.userHandle)
        multipeerService.startAdvertisingAndBrowsing(userHandle: trimmed, status: .normal)
        bleBeaconService.startScanningAndAdvertising(userHandle: trimmed)
    }
    
    func connectToPeer(_ peer: PeerDevice) {
        self.selectedPeer = peer
        HapticManager.mediumImpact()
        if let mcPeerID = peer.mcPeerID {
            multipeerService.connectToPeer(peerID: mcPeerID)
        }
    }
    
    func onAppear() {
        bleBeaconService.startHighFrequencyRadarScan()
        fetchFriends()
    }
    
    func onDisappear() {
        bleBeaconService.stopHighFrequencyRadarScan()
    }
    
    func toggleScanning() {
        isScanning.toggle()
        if isScanning {
            multipeerService.startAdvertisingAndBrowsing(userHandle: broadcastName, status: .normal)
            bleBeaconService.startHighFrequencyRadarScan()
        } else {
            multipeerService.stopAdvertisingAndBrowsing()
            bleBeaconService.stopHighFrequencyRadarScan()
        }
    }
    
    // MARK: - Friends Management
    
    @Published var friends: [SDFriend] = []
    
    func fetchFriends() {
        self.friends = SwiftDataService.shared.fetchFriends()
    }
    
    func isFriend(_ peer: PeerDevice) -> Bool {
        return friends.contains(where: { $0.nodeID == peer.id && $0.status == .accepted })
    }
    
    func friendStatus(for peerID: String) -> FriendStatus {
        return friends.first(where: { $0.nodeID == peerID })?.status ?? .none
    }
    
    func addFriend(_ peer: PeerDevice) {
        Task {
            let localNodeID = NodeIdentity.shared.nodeID
            let handle = NodeIdentity.shared.displayName
            
            let requestID = await SwiftDataService.shared.persistenceActor.localSendFriendRequest(nodeID: peer.id, displayName: peer.displayName)
            
            let newMessage = Message(
                id: requestID,
                originID: localNodeID,
                destinationID: peer.id,
                senderID: localNodeID,
                senderName: handle,
                channelID: nil,
                text: "FRIEND_REQUEST",
                timestamp: Date(),
                isSOS: false,
                emergencyStatus: .normal,
                hopsCount: 0,
                type: .friendRequest
            )
            
            // Broadcast over the mesh
            MultipeerService.shared.broadcast(message: newMessage)
            
            // Enqueue in store-and-forward queue to ensure delivery if mesh is offline
            await SwiftDataService.shared.persistenceActor.enqueuePendingMessage(
                messageID: requestID,
                originID: localNodeID,
                destinationID: peer.id,
                recipientName: peer.displayName,
                senderName: handle,
                text: "FRIEND_REQUEST",
                channel: peer.id,
                isSOS: false,
                priorityRaw: 1, // Medium priority
                statusRaw: "QUEUED",
                queueRoleRaw: "ORIGIN",
                hopsCount: 0,
                ttl: Constants.Mesh.maxMeshHops,
                messageTypeRaw: P2PMessageType.friendRequest.rawValue
            )
            
            DispatchQueue.main.async {
                self.fetchFriends()
                HapticManager.successFeedback()
            }
        }
    }
    
    func acceptFriendRequest(_ peerID: String) {
        Task {
            let localNodeID = NodeIdentity.shared.nodeID
            let handle = NodeIdentity.shared.displayName
            
            await SwiftDataService.shared.persistenceActor.handleFriendAccept(from: peerID)
            NotificationCenter.default.post(
                name: .didBecomeFriend,
                object: nil,
                userInfo: ["nodeID": peerID]
            )
            
            let newMessage = Message(
                originID: localNodeID,
                destinationID: peerID,
                senderID: localNodeID,
                senderName: handle,
                channelID: nil,
                text: "FRIEND_ACCEPT",
                timestamp: Date(),
                type: .friendAccept
            )
            
            MultipeerService.shared.broadcast(message: newMessage)
            
            await SwiftDataService.shared.persistenceActor.enqueuePendingMessage(
                messageID: newMessage.id, originID: localNodeID, destinationID: peerID,
                recipientName: peerID, senderName: handle, text: "FRIEND_ACCEPT",
                channel: peerID, isSOS: false, priorityRaw: 1, statusRaw: "QUEUED",
                queueRoleRaw: "ORIGIN", hopsCount: 0, ttl: Constants.Mesh.maxMeshHops,
                messageTypeRaw: P2PMessageType.friendAccept.rawValue
            )
            
            DispatchQueue.main.async {
                self.fetchFriends()
                HapticManager.successFeedback()
            }
        }
    }
    
    func declineFriendRequest(_ peerID: String) {
        Task {
            let localNodeID = NodeIdentity.shared.nodeID
            let handle = NodeIdentity.shared.displayName
            
            await SwiftDataService.shared.persistenceActor.handleFriendDecline(from: peerID)
            
            let newMessage = Message(
                originID: localNodeID,
                destinationID: peerID,
                senderID: localNodeID,
                senderName: handle,
                channelID: nil,
                text: "FRIEND_DECLINE",
                timestamp: Date(),
                type: .friendDecline
            )
            
            MultipeerService.shared.broadcast(message: newMessage)
            
            DispatchQueue.main.async {
                self.fetchFriends()
                HapticManager.mediumImpact()
            }
        }
    }
    
    func removeFriend(_ peer: PeerDevice) {
        Task {
            await SwiftDataService.shared.persistenceActor.removeFriend(nodeID: peer.id)
            DispatchQueue.main.async {
                self.fetchFriends()
                HapticManager.mediumImpact()
            }
        }
    }
}


