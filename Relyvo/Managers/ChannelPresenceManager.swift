//
//  ChannelPresenceManager.swift
//  Relyvo
//
//  Offline Channel Presence Tracking & Periodic Discovery Heartbeats Engine
//

import Foundation
import Combine
import UIKit
import os

/// Model representing an active tuned-in peer on a specific channel.
struct ChannelPeer: Identifiable, Equatable, Hashable, Codable {
    let nodeID: UUID
    let alias: String
    let channelID: String
    var lastSeen: Date
    var hopCount: UInt8
    var isDirectPeer: Bool
    
    var id: UUID { nodeID }
}

/// Thread-safe registry and heartbeat engine for offline mesh channel presence.
final class ChannelPresenceManager: ObservableObject {
    
    static let shared = ChannelPresenceManager()
    
    /// TTL threshold before a silent node is considered inactive/evicted (30 seconds).
    static let presenceTTL: TimeInterval = 30.0
    
    /// Heartbeat broadcast interval (10 seconds).
    static let heartbeatInterval: TimeInterval = 10.0
    
    /// Eviction reaper interval (5 seconds).
    static let reaperInterval: TimeInterval = 5.0
    
    /// Live members tuned into the currently selected channel.
    @Published private(set) var activeChannelMembers: [ChannelPeer] = []
    
    /// Currently monitored active channel ID.
    private(set) var currentChannelID: String = "CH-1 EMERGENCY"
    
    /// Internal thread-safe store: [ChannelID (uppercased): [NodeUUID: ChannelPeer]]
    private var registry: [String: [UUID: ChannelPeer]] = [:]
    private let lock = NSLock()
    
    private var heartbeatTimer: Timer?
    private var reaperTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupForegroundObserver()
    }
    
    // MARK: - Lifecycle Engine
    
    /// Starts background periodic presence broadcasting and inactivity reaper timers.
    func startPresenceEngine() {
        lock.lock()
        defer { lock.unlock() }
        
        stopTimers()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 1. Periodic Heartbeat Broadcast (every 10s)
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
                self?.broadcastHeartbeat()
            }
            
            // 2. Inactivity Reaper Timer (every 5s)
            self.reaperTimer = Timer.scheduledTimer(withTimeInterval: Self.reaperInterval, repeats: true) { [weak self] _ in
                self?.reapInactivePeers()
            }
            
            // Send initial discovery heartbeat immediately
            self.broadcastHeartbeat()
        }
        
        AppLogger.multipeer.info("[CHANNEL_PRESENCE] Presence engine started (Heartbeat=\(Self.heartbeatInterval)s, TTL=\(Self.presenceTTL)s)")
    }
    
    /// Stops all running presence timers.
    func stopPresenceEngine() {
        lock.lock()
        defer { lock.unlock() }
        stopTimers()
        AppLogger.multipeer.info("[CHANNEL_PRESENCE] Presence engine stopped")
    }
    
    private func stopTimers() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        reaperTimer?.invalidate()
        reaperTimer = nil
    }
    
    private func setupForegroundObserver() {
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                AppLogger.multipeer.info("[CHANNEL_PRESENCE] App entered foreground — broadcasting immediate discovery ping")
                self?.broadcastHeartbeat()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Channel Switching & Heartbeat Transmission
    
    /// Updates the active monitored channel, isolates member lists, and broadcasts an immediate heartbeat.
    func setActiveChannel(_ channelID: String) {
        lock.lock()
        self.currentChannelID = channelID
        let normalized = channelID.uppercased()
        let members: [ChannelPeer] = self.registry[normalized]?.values.map { $0 }.sorted(by: { $0.alias < $1.alias }) ?? []
        lock.unlock()
        
        DispatchQueue.main.async {
            self.activeChannelMembers = members
        }
        
        AppLogger.multipeer.info("[CHANNEL_PRESENCE] Switched active channel to '\(channelID)' — \(members.count) cached members")
        
        // Trigger immediate heartbeat broadcast on the new channel
        broadcastHeartbeat()
    }
    
    /// Broadcasts a compact CHANNEL_PING packet with node alias and active channel.
    func broadcastHeartbeat() {
        let localAlias = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        let originNodeID = NodeIdentity.shared.nodeID
        let channel = self.currentChannelID
        
        let pingMsg = Message(
            id: UUID(),
            originID: originNodeID,
            destinationID: "BROADCAST",
            senderID: originNodeID,
            senderName: localAlias,
            channelID: channel,
            text: localAlias,
            timestamp: Date(),
            hopsCount: 0,
            ttl: Constants.Mesh.maxMeshHops,
            type: .channelSync
        )
        
        MultipeerService.shared.broadcast(message: pingMsg)
        let rawByte = MeshChannelByte.from(channelID: channel).rawValue
        AppLogger.multipeer.info("""
        [DIAG_HEARTBEAT_TX]
        channel=\(channel)
        alias=\(localAlias)
        rawByte=\(rawByte)
        """)
        AppLogger.multipeer.info("[CHANNEL_PRESENCE_TX] Broadcasted heartbeat ping for '\(localAlias)' on [\(channel)]")
    }
    
    // MARK: - Ingestion & Registry Store
    
    /// Ingests an incoming CHANNEL_PING packet and updates the channel member registry.
    func processHeartbeat(
        originNodeID: UUID,
        alias: String,
        channelID: String,
        hopCount: UInt8,
        isDirectPeer: Bool
    ) {
        let cleanAlias = String(alias.prefix(32)) // Enforce 32-byte max safety guard
        let normalizedChannel = channelID.uppercased()
        let now = Date()
        
        let matches = (normalizedChannel == self.currentChannelID.uppercased())
        AppLogger.multipeer.info("""
        [DIAG_HEARTBEAT_RX]
        senderPeer=\(cleanAlias)
        senderChannel=\(channelID)
        localChannel=\(self.currentChannelID)
        matches=\(matches)
        hops=\(hopCount)
        isDirect=\(isDirectPeer)
        """)
        
        let peer = ChannelPeer(
            nodeID: originNodeID,
            alias: cleanAlias,
            channelID: channelID,
            lastSeen: now,
            hopCount: hopCount,
            isDirectPeer: isDirectPeer
        )
        
        lock.lock()
        if registry[normalizedChannel] == nil {
            registry[normalizedChannel] = [:]
        }
        let isNewPeer = (registry[normalizedChannel]?[originNodeID] == nil)
        registry[normalizedChannel]?[originNodeID] = peer
        
        let isCurrentChannel = (normalizedChannel == currentChannelID.uppercased())
        let updatedMembers: [ChannelPeer]? = isCurrentChannel ? (registry[normalizedChannel]?.values.map { $0 }.sorted(by: { $0.alias < $1.alias }) ?? []) : nil
        lock.unlock()
        
        AppLogger.multipeer.info("[CHANNEL_PRESENCE_UPDATE] peer=\(cleanAlias) id=\(originNodeID.uuidString) channel=\(channelID) hops=\(hopCount)")
        
        if isNewPeer {
            MultipeerService.shared.flushPendingStoreAndForwardQueue()
            AppLogger.multipeer.info("[OFFLINE_QUEUE_TRIGGER] Triggered queue flush on new peer discovery: \(cleanAlias)")
        }
        
        if let members = updatedMembers {
            DispatchQueue.main.async {
                self.activeChannelMembers = members
            }
        }
    }
    
    // MARK: - TTL Eviction Reaper
    
    /// Scans registry and removes peers that have not sent a heartbeat within the 30s TTL.
    func reapInactivePeers() {
        let now = Date()
        var currentChannelChanged = false
        
        lock.lock()
        for (chKey, members) in registry {
            for (nodeID, peer) in members {
                let age = now.timeIntervalSince(peer.lastSeen)
                if age > Self.presenceTTL {
                    registry[chKey]?.removeValue(forKey: nodeID)
                    AppLogger.multipeer.info("[CHANNEL_PRESENCE_EVICTED] peer=\(peer.alias) id=\(nodeID.uuidString) channel=\(peer.channelID) reason=HEARTBEAT_TIMEOUT age=\(Int(age))s")
                    
                    if chKey == currentChannelID.uppercased() {
                        currentChannelChanged = true
                    }
                }
            }
        }
        
        let updatedMembers: [ChannelPeer]? = currentChannelChanged ? (registry[currentChannelID.uppercased()]?.values.map { $0 }.sorted(by: { $0.alias < $1.alias }) ?? []) : nil
        lock.unlock()
        
        if let members = updatedMembers {
            DispatchQueue.main.async {
                self.activeChannelMembers = members
            }
        }
    }
    
    // MARK: - Peer Disconnect Handling
    
    /// Purges a disconnected peer from all channel registries immediately.
    func handlePeerDisconnected(nodeID: UUID) {
        lock.lock()
        var currentChannelChanged = false
        for (chKey, members) in registry {
            if members[nodeID] != nil {
                registry[chKey]?.removeValue(forKey: nodeID)
                if chKey == currentChannelID.uppercased() {
                    currentChannelChanged = true
                }
            }
        }
        let updatedMembers: [ChannelPeer]? = currentChannelChanged ? (registry[currentChannelID.uppercased()]?.values.map { $0 }.sorted(by: { $0.alias < $1.alias }) ?? []) : nil
        lock.unlock()
        
        AppLogger.multipeer.info("[CHANNEL_PRESENCE_PURGED_DISCONNECT] id=\(nodeID.uuidString)")
        
        if let members = updatedMembers {
            DispatchQueue.main.async {
                self.activeChannelMembers = members
            }
        }
    }
    
    /// Purges by string node ID / MCPeerID displayName.
    func handlePeerDisconnected(nodeIDString: String) {
        if let uuid = UUID(uuidString: nodeIDString) {
            handlePeerDisconnected(nodeID: uuid)
            return
        }
        
        // Match by alias or string prefix if non-UUID
        lock.lock()
        var currentChannelChanged = false
        for (chKey, members) in registry {
            for (nodeID, peer) in members where peer.alias == nodeIDString || peer.nodeID.uuidString.hasPrefix(nodeIDString) {
                registry[chKey]?.removeValue(forKey: nodeID)
                if chKey == currentChannelID.uppercased() {
                    currentChannelChanged = true
                }
            }
        }
        let updatedMembers: [ChannelPeer]? = currentChannelChanged ? (registry[currentChannelID.uppercased()]?.values.map { $0 }.sorted(by: { $0.alias < $1.alias }) ?? []) : nil
        lock.unlock()
        
        if let members = updatedMembers {
            DispatchQueue.main.async {
                self.activeChannelMembers = members
            }
        }
    }
    
    // MARK: - Testing & Inspection
    
    /// Returns members for a given channel (for unit tests).
    func members(for channelID: String) -> [ChannelPeer] {
        lock.lock()
        defer { lock.unlock() }
        return registry[channelID.uppercased()]?.values.map { $0 }.sorted(by: { $0.alias < $1.alias }) ?? []
    }
    
    /// Clears the entire registry (for testing).
    func clearAll() {
        lock.lock()
        registry.removeAll()
        lock.unlock()
        DispatchQueue.main.async {
            self.activeChannelMembers = []
        }
    }
}
