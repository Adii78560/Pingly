//
//  MeshOutboundQueue.swift
//  Relyvo
//
//  Thread-safe outbound message prioritization and backpressure queue for Multipeer Connectivity.
//  Prevents socket buffer saturation on BLE and Wi-Fi links by capping pending packets per peer,
//  prioritizing real-time voice and floor control over text and transcripts, and dropping stale
//  low-priority packets under heavy network backpressure.
//

import Foundation
import MultipeerConnectivity
import os

// MARK: - Packet Priority

enum MeshPacketPriority: Int, Comparable {
    case bulk = 0
    case normal = 1
    case realtime = 2
    case high = 3
    case critical = 4
    
    static func < (lhs: MeshPacketPriority, rhs: MeshPacketPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Outbound Packet Item

struct OutboundPacketItem {
    let id: UUID
    let data: Data
    let priority: MeshPacketPriority
    let isReliable: Bool
    let timestamp: Date
    let descriptionTag: String
}

// MARK: - Mesh Outbound Queue

final class MeshOutboundQueue {
    static let shared = MeshOutboundQueue()
    
    /// Max pending outbound packets queued per peer before backpressure drop policy activates.
    static let maxQueuePerPeer: Int = 50
    
    private let lock = NSLock()
    private var peerQueues: [MCPeerID: [OutboundPacketItem]] = [:]
    private var isDispatching: [MCPeerID: Bool] = [:]
    
    private let dispatchQueue = DispatchQueue(label: "com.relyvo.mesh.outboundQueue", qos: .userInitiated)
    
    private init() {}
    
    // MARK: - Enqueue Operations
    
    /// Enqueues a packet for transmission to a specific list of peers with priority and backpressure checks.
    func enqueue(
        data: Data,
        priority: MeshPacketPriority,
        isReliable: Bool = true,
        toPeers peers: [MCPeerID],
        session: MCSession?,
        tag: String = "PACKET"
    ) {
        guard let session = session, !peers.isEmpty else { return }
        let packetID = UUID()
        let item = OutboundPacketItem(
            id: packetID,
            data: data,
            priority: priority,
            isReliable: isReliable,
            timestamp: Date(),
            descriptionTag: tag
        )
        
        lock.lock()
        for peer in peers {
            var queue = peerQueues[peer] ?? []
            
            // Flow Control / Backpressure Check
            if queue.count >= Self.maxQueuePerPeer {
                // Drop policy: drop bulk -> realtime -> normal -> high -> critical
                if let bulkIndex = queue.firstIndex(where: { $0.priority == .bulk }) {
                    let dropped = queue.remove(at: bulkIndex)
                    AppLogger.multipeer.warning("Drop: BULK \(dropped.id.uuidString)")
                    RelaynTransportDiagnosticsManager.shared.incrementRelayDropped()
                } else if let realtimeIndex = queue.firstIndex(where: { $0.priority == .realtime }) {
                    let dropped = queue.remove(at: realtimeIndex)
                    AppLogger.multipeer.warning("Drop: REALTIME \(dropped.id.uuidString)")
                    RelaynTransportDiagnosticsManager.shared.incrementRelayDropped()
                } else if let normalIndex = queue.firstIndex(where: { $0.priority == .normal }) {
                    let dropped = queue.remove(at: normalIndex)
                    AppLogger.multipeer.warning("Drop: NORMAL \(dropped.id.uuidString)")
                    RelaynTransportDiagnosticsManager.shared.incrementRelayDropped()
                } else if let highIndex = queue.firstIndex(where: { $0.priority == .high }) {
                    let dropped = queue.remove(at: highIndex)
                    AppLogger.multipeer.warning("Drop: HIGH \(dropped.id.uuidString)")
                    RelaynTransportDiagnosticsManager.shared.incrementRelayDropped()
                } else {
                    let dropped = queue.removeFirst()
                    AppLogger.multipeer.warning("Drop: CRITICAL \(dropped.id.uuidString)")
                    RelaynTransportDiagnosticsManager.shared.incrementRelayDropped()
                }
            }
            
            // High priority items are inserted ahead of lower priority items
            if let insertIndex = queue.firstIndex(where: { $0.priority < priority }) {
                queue.insert(item, at: insertIndex)
            } else {
                queue.append(item)
            }
            
            peerQueues[peer] = queue
            
            AppLogger.multipeer.info("""
            [DIAG_QUEUE_ENQUEUE]
            packetID=\(packetID.uuidString.prefix(8))
            priority=\(priority.rawValue)
            targetPeer=\(peer.displayName)
            queueDepth=\(queue.count)
            isReliable=\(isReliable)
            tag=\(tag)
            """)
        }
        lock.unlock()
        
        // Trigger worker dispatch for each peer
        for peer in peers {
            triggerDispatch(for: peer, session: session)
        }
    }
    
    // MARK: - Dispatch Worker
    
    private func triggerDispatch(for peer: MCPeerID, session: MCSession) {
        dispatchQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            if self.isDispatching[peer] == true {
                self.lock.unlock()
                return
            }
            self.isDispatching[peer] = true
            self.lock.unlock()
            
            self.processQueue(for: peer, session: session)
        }
    }
    
    private func processQueue(for peer: MCPeerID, session: MCSession) {
        while true {
            lock.lock()
            guard var queue = peerQueues[peer], !queue.isEmpty else {
                isDispatching[peer] = false
                lock.unlock()
                break
            }
            let item = queue.removeFirst()
            peerQueues[peer] = queue
            lock.unlock()
            
            // Check if peer is still connected in session
            guard session.connectedPeers.contains(peer) else {
                AppLogger.multipeer.info("[OUTBOUND_QUEUE] Skipping dispatch for disconnected peer: \(peer.displayName)")
                flushQueue(for: peer)
                break
            }
            
            do {
                try session.send(item.data, toPeers: [peer], with: item.isReliable ? .reliable : .unreliable)
                RelaynTransportDiagnosticsManager.shared.incrementTxFrames()
                AppLogger.multipeer.info("""
                [DIAG_QUEUE_SEND]
                packetID=\(item.id.uuidString.prefix(8))
                priority=\(item.priority == .high ? "HIGH" : "LOW")
                targetPeer=\(peer.displayName)
                success=true
                connectedPeerCount=\(session.connectedPeers.count)
                error=none
                """)
            } catch {
                AppLogger.multipeer.error("""
                [DIAG_QUEUE_SEND]
                packetID=\(item.id.uuidString.prefix(8))
                priority=\(item.priority == .high ? "HIGH" : "LOW")
                targetPeer=\(peer.displayName)
                success=false
                connectedPeerCount=\(session.connectedPeers.count)
                error=\(error.localizedDescription)
                """)
                AppLogger.multipeer.error("""
                [OUTBOUND_DISPATCH_ERR]
                peer=\(peer.displayName)
                packetID=\(item.id.uuidString)
                tag=\(item.descriptionTag)
                error=\(error.localizedDescription)
                """)
            }
        }
    }
    
    // MARK: - Peer Churn & Flush Controls
    
    /// Flushes all pending outbound packets for a disconnected peer.
    func flushQueue(for peer: MCPeerID) {
        lock.lock()
        let droppedCount = peerQueues[peer]?.count ?? 0
        peerQueues.removeValue(forKey: peer)
        isDispatching.removeValue(forKey: peer)
        lock.unlock()
        
        if droppedCount > 0 {
            AppLogger.multipeer.info("[OUTBOUND_QUEUE_FLUSH] Purged \(droppedCount) pending packets for disconnected peer \(peer.displayName)")
        }
    }
    
    /// Flushes all outbound queues across all peers.
    func flushAll() {
        lock.lock()
        peerQueues.removeAll()
        isDispatching.removeAll()
        lock.unlock()
        AppLogger.multipeer.info("[OUTBOUND_QUEUE_FLUSH] Flushed all peer outbound queues.")
    }
}
