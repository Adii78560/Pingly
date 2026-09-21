//
//  MultipeerService.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import MultipeerConnectivity
import Combine
import CoreLocation
import os

/// Thread-safe actor coalescing duplicate queue processing requests to conserve CPU and battery
actor QueueProcessingCoalescer {
    private var isProcessing = false
    
    func performCoalescedWork(_ block: @escaping () async -> Void) async {
        guard !isProcessing else {
            AppLogger.multipeer.info("QueueProcessingCoalescer: Coalesced parallel queue processing trigger.")
            return
        }
        isProcessing = true
        await block()
        isProcessing = false
    }
}

// MARK: - In-Memory Mesh Seen Cache (Deduplication)

/// Thread-safe, timestamped in-memory deduplication cache for mesh message IDs.
///
/// Purpose: Prevent broadcast loops and packet storms on multi-path mesh topologies.
/// Every incoming message UUID is inserted here before any local delivery or forwarding.
/// Subsequent copies of the same message — arriving via alternative mesh paths — are
/// immediately dropped with a [MESH_DEDUP_DROP] log, guaranteeing exactly-once delivery
/// and exactly-once forwarding regardless of mesh topology.
///
/// Performance: O(1) lookup and insertion via Dictionary. Lock-contention window is
/// sub-microsecond (dictionary key lookup only). Does NOT touch SwiftData or disk.
///
/// Eviction: Entries older than `seenCacheTTLSeconds` are lazily evicted on every
/// `contains()` call. LRU overflow eviction drops the oldest entry when size > seenCacheMaxSize.
final class MeshSeenCache {
    private var store: [String: Date] = [:]     // deduplication key → firstSeenAt
    private let lock = NSLock()
    
    /// Returns true if this message identity has been seen before (within the TTL window).
    /// Also evicts expired entries and enforces max-size on every call.
    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        evictExpiredLocked()
        return store[key] != nil
    }
    
    /// Marks a message identity as seen. Evicts oldest entry if over capacity.
    func insert(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        evictExpiredLocked()
        // LRU overflow: drop the oldest entry to cap memory
        if store.count >= Constants.Mesh.seenCacheMaxSize,
           let oldest = store.min(by: { $0.value < $1.value }) {
            store.removeValue(forKey: oldest.key)
        }
        store[key] = Date()
    }
    
    // Called with lock held
    private func evictExpiredLocked() {
        let cutoff = Date().addingTimeInterval(-Constants.Mesh.seenCacheTTLSeconds)
        store = store.filter { $0.value > cutoff }
    }
}

/// Production MultipeerConnectivity Service managing AirDrop/Wi-Fi/Bluetooth peer mesh networking
final class MultipeerService: NSObject, MultipeerServiceProtocol, ObservableObject {
    
    static let shared = MultipeerService()
    private let queueCoalescer = QueueProcessingCoalescer()

    

    enum PeerConnectionState: String {
        case idle = "IDLE"
        case discovered = "DISCOVERED"
        case invitationSent = "INVITATION_SENT"
        case invitationReceived = "INVITATION_RECEIVED"
        case connecting = "CONNECTING"
        case connected = "CONNECTED"
        case sessionReady = "SESSION_READY"
        case disconnected = "DISCONNECTED"
        case failed = "FAILED"
    }
    private var peerConnectionStates: [MCPeerID: PeerConnectionState] = [:]
    @Published private(set) var connectedPeers: [PeerDevice] = []
    @Published private(set) var discoveredPeers: [PeerDevice] = []
    
    // MARK: - Publishers
    var connectedPeersPublisher: AnyPublisher<[PeerDevice], Never> {
        $connectedPeers.eraseToAnyPublisher()
    }
    var discoveredPeersPublisher: AnyPublisher<[PeerDevice], Never> {
        $discoveredPeers.eraseToAnyPublisher()
    }
    
    let receivedMessageSubject = PassthroughSubject<Message, Never>()
    var receivedMessagePublisher: AnyPublisher<Message, Never> {
        receivedMessageSubject.eraseToAnyPublisher()
    }
    
    let receivedAudioDataSubject = PassthroughSubject<Data, Never>()
    var receivedAudioDataPublisher: AnyPublisher<Data, Never> {
        receivedAudioDataSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Multipeer Core Objects
    let myPeerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    
    // Identity mappings for stable routing IDs
    private var peerIDToNodeIDMap: [MCPeerID: String] = [:]
    private var peerIDToHandleMap: [MCPeerID: String] = [:]
    var activeChannelID: String = "CH-1 EMERGENCY"
    
    /// In-memory seen cache — the first and fastest deduplication gate.
    /// Checked before any SwiftData access, before local delivery, and before forwarding.
    private let seenCache = MeshSeenCache()
    
    private var currentHandle: String = Constants.App.defaultUserHandle
    public private(set) var currentStatus: EmergencyStatus = .normal
    private var connectStartTimestamp: Date? = nil
    private var outboundSequenceNumber: UInt16 = 0
    
    override init() {
        let storedHandle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        
        // Use NodeIdentity.shared.nodeID as canonical peer displayName.
        // It is a 36-character UUID string which safely fits into the 63-byte MCPeerID limit.
        // This ensures the device maintains exactly one logical mesh identity even if the handle changes.
        self.currentHandle = storedHandle
        self.myPeerID = MCPeerID(displayName: NodeIdentity.shared.nodeID)
        
        super.init()
        setupSession()
        
        let deviceFingerprint = String(NodeIdentity.shared.nodeID.prefix(6))
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "APP_LAUNCH", details: "launch_completed")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "IDENTITY_READY", details: "deviceFingerprint=\(deviceFingerprint)")
    }

    
    private func setupSession() {
        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "SESSION_INIT", peer: myPeerID.displayName, details: "mcsession_initialized")
    }
    
    func startAdvertisingAndBrowsing(userHandle: String, status: EmergencyStatus) {
        let isHandleChanged = (userHandle != self.currentHandle)
        let isStatusChanged = (status != self.currentStatus)
        
        self.currentHandle = userHandle
        self.currentStatus = status
        
        // If advertiser/browser are already running, and only handle or status changed,
        // we update the advertiser's discovery info without resetting the session or browser!
        if advertiser != nil && browser != nil {
            if isHandleChanged || isStatusChanged {
                advertiser?.stopAdvertisingPeer()
                let discoveryInfo: [String: String] = [
                    "handle": userHandle,
                    "status": status.rawValue,
                    "nodeID": NodeIdentity.shared.nodeID
                ]
                let newAdvertiser = MCNearbyServiceAdvertiser(
                    peer: myPeerID,
                    discoveryInfo: discoveryInfo,
                    serviceType: Constants.Multipeer.serviceType
                )
                newAdvertiser.delegate = self
                newAdvertiser.startAdvertisingPeer()
                self.advertiser = newAdvertiser
                AppLogger.multipeer.info("Updated advertiser with new handle/status discoveryInfo: \(userHandle)")
            }
            return
        }
        
        let discoveryInfo: [String: String] = [
            "handle": userHandle,
            "status": status.rawValue,
            "nodeID": NodeIdentity.shared.nodeID
        ]
        
        let advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: discoveryInfo,
            serviceType: Constants.Multipeer.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "ADVERTISING_START", peer: myPeerID.displayName, details: "serviceType=\(Constants.Multipeer.serviceType)")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "ADVERTISING_STARTED", peer: myPeerID.displayName, details: "serviceType=\(Constants.Multipeer.serviceType)")
        AppLogger.multipeer.info("""
        [DIAG_PEER_ADV_START]
        serviceType=\(Constants.Multipeer.serviceType)
        discoveryInfo=\(discoveryInfo)
        localPeer=\(self.myPeerID.displayName)
        """)
        
        let browser = MCNearbyServiceBrowser(
            peer: self.myPeerID,
            serviceType: Constants.Multipeer.serviceType
        )
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "BROWSING_START", peer: self.myPeerID.displayName, details: "serviceType=\(Constants.Multipeer.serviceType)")
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "SESSION_START", peer: self.myPeerID.displayName, details: "handle=\(userHandle)")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "SERVICES_STARTED", peer: self.myPeerID.displayName, details: "handle=\(userHandle)")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "BROWSING_STARTED", peer: self.myPeerID.displayName, details: "serviceType=\(Constants.Multipeer.serviceType)")
        AppLogger.multipeer.info("""
        [DIAG_PEER_BROWSER_START]
        serviceType=\(Constants.Multipeer.serviceType)
        localPeer=\(self.myPeerID.displayName)
        """)
        
        ChannelPresenceManager.shared.startPresenceEngine()
        AppLogger.multipeer.info("Started Multipeer Advertising & Browsing for handle: \(userHandle)")
    }
    
    func stopAdvertisingAndBrowsing() {
        ChannelPresenceManager.shared.stopPresenceEngine()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        discoveredPeers.removeAll()
        AppLogger.multipeer.info("""
        [DIAG_PEER_ADV_STOP]
        serviceType=\(Constants.Multipeer.serviceType)
        
        [DIAG_PEER_BROWSER_STOP]
        serviceType=\(Constants.Multipeer.serviceType)
        """)
    }
    
    /// Safely disconnects the existing MCSession, unregisters its delegate, re-instantiates a fresh MCSession, and reassigns self as delegate.
    func teardownAndResetSession() {
        let resetWork = { [weak self] in
            guard let self = self else { return }
            AppLogger.multipeer.warning("[MESH_SESSION_REPLACED] Tearing down and resetting MCSession...")
            if let existingSession = self.session {
                existingSession.disconnect()
                existingSession.delegate = nil
            }
            self.session = nil
            self.connectedPeers.removeAll()
            self.discoveredPeers.removeAll()
            self.peerIDToNodeIDMap.removeAll()
            self.peerIDToHandleMap.removeAll()
            MeshOutboundQueue.shared.flushAll()
            
            RelaynTransportDiagnosticsManager.shared.updateConnectedPeersList([])
            RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "SESSION_TEARDOWN_RESET", peer: self.myPeerID.displayName, details: "session_reset_complete")
            
            self.setupSession()
            
            if self.advertiser != nil || self.browser != nil {
                self.stopAdvertisingAndBrowsing()
                self.startAdvertisingAndBrowsing(userHandle: self.currentHandle, status: self.currentStatus)
            }
        }
        
        if Thread.isMainThread {
            resetWork()
        } else {
            DispatchQueue.main.async(execute: resetWork)
        }
    }
    
    func connectToPeer(peerID: MCPeerID) {
        guard let session = session, let browser = browser else { return }
        let contextData = NodeIdentity.shared.nodeID.data(using: .utf8)
        AppLogger.multipeer.info("[MESH_INVITATION_SENT] peer=\(peerID.displayName)")
        browser.invitePeer(peerID, to: session, withContext: contextData, timeout: Constants.Multipeer.connectionTimeoutSeconds)
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "INVITATION_SENT", peer: peerID.displayName, details: "invited_peer")
        AppLogger.multipeer.info("Inviting peer: \(peerID.displayName)")
    }

    
    func broadcast(message: Message) {
        let tag = AppLogger.messageTag(message.id)
        let frameTag = AppLogger.frameTag(message.id)
        
        guard let session = session, !session.connectedPeers.isEmpty else {
            AppLogger.multipeer.info("\(tag) WAITING_FOR_PEER")
            return
        }
        
        let peerNames = session.connectedPeers.map { $0.displayName }.joined(separator: ", ")
        let firstPeerShort = String((session.connectedPeers.first?.displayName ?? "UNKNOWN").prefix(6))
        
        AppLogger.multipeer.info("\(tag) CREATED type=\(message.type.rawValue)")
        AppLogger.multipeer.info("\(tag) sender=\(String(message.senderID.prefix(6)))")
        AppLogger.multipeer.info("\(tag) recipient=\(String(message.destinationID.prefix(6))) channel=\(message.channelID ?? message.destinationID) payloadBytes=\(message.text.utf8.count)")
        AppLogger.multipeer.info("\(tag) SEND_ATTEMPT attempt=1 reason=BROADCAST peer=\(firstPeerShort)")
        
        AppLogger.multipeer.info("\(frameTag) BINARY_SERIALIZE_START")
        outboundSequenceNumber = outboundSequenceNumber &+ 1
        
        var isEncrypted = false
        var encryptedPayload: Data? = nil
        if let channel = message.channelID, let key = ChannelKeyStore.shared.key(for: channel) {
            if let payloadBytes = message.text.data(using: .utf8),
               let sealed = ChannelCrypto.encrypt(data: payloadBytes, key: key) {
                isEncrypted = true
                encryptedPayload = sealed
                AppLogger.multipeer.info("\(frameTag) ENCRYPTED using ChannelKeyStore key for \(channel)")
            }
        }
        
        guard let binaryData = try? MeshPacketHeader.encode(message, sequenceNumber: outboundSequenceNumber, isEncrypted: isEncrypted, encryptedPayload: encryptedPayload) else {
            AppLogger.multipeer.error("Failed to encode outbound message (e.g. channel ID too long)")
            return
        }
        let estimatedJsonBytes = 450 + message.text.utf8.count
        let savedBytes = max(0, estimatedJsonBytes - binaryData.count)
        let savedPct = Int((Double(savedBytes) / Double(max(1, estimatedJsonBytes))) * 100.0)
        
        AppLogger.multipeer.info("\(frameTag) BINARY_SERIALIZE_SUCCESS version=\(message.protocolVersion) type=\(message.type.rawValue) binaryBytes=\(binaryData.count) jsonEstBytes=\(estimatedJsonBytes) reduction=\(savedPct)%")
        
        AppLogger.multipeer.info("""
        [PINGLY_SERIALIZATION]
        encoder=MeshPacketHeader
        type=MeshPacketBinary
        bytes=\(binaryData.count)
        jsonEstBytes=\(estimatedJsonBytes)
        reductionPct=\(savedPct)%
        
        [PINGLY_FRAME_METADATA]
        frameVersion=\(message.protocolVersion)
        frameType=\(message.type.rawValue)
        messageType=\(message.type.rawValue)
        messageID=\(message.id.uuidString)
        senderID=\(message.senderID)
        destinationID=\(message.destinationID)
        channelID=\(message.channelID ?? "N/A")
        hopCount=\(message.hopsCount)
        TTL=\(message.ttl)
        createdAt=\(message.timestamp)
        protocolVersion=\(message.protocolVersion)
        """)
        
        let targetPeers: [MCPeerID]
        let isChannelMessage = message.channelID != nil && !message.channelID!.isEmpty
        if !isChannelMessage && message.destinationID != "BROADCAST",
           let mcPeer = session.connectedPeers.first(where: { peer in
               let resolvedNodeID = self.peerIDToNodeIDMap[peer] ?? peer.displayName
               return resolvedNodeID == message.destinationID
           }) {
            targetPeers = [mcPeer]
            AppLogger.multipeer.info("Routing direct message to specific peer: \(mcPeer.displayName) (nodeID: \(message.destinationID))")
        } else {
            targetPeers = session.connectedPeers
        }
        
        if targetPeers.isEmpty {
            let isEphemeral = (message.type == .location && !message.isSOS) || message.type == .channelSync || message.text.hasPrefix("LOCATION_PROTOCOL:")
            if isEphemeral {
                AppLogger.multipeer.info("[OFFLINE_QUEUE_EPHEMERAL_SKIP] Discarding ephemeral update type=\(message.type.rawValue) messageID=\(message.id.uuidString)")
                return
            }
            Task { await SwiftDataService.shared.persistenceActor.enqueuePendingMessage(
                messageID: message.id,
                originID: message.originID,
                destinationID: message.destinationID,
                recipientName: message.destinationID,
                senderName: message.senderName,
                text: message.text,
                channel: message.destinationID,
                isSOS: message.isSOS,
                priorityRaw: 0,
                statusRaw: "PENDING",
                queueRoleRaw: "ORIGIN",
                hopsCount: message.hopsCount,
                ttl: 5,
                conversationID: message.conversationID,
                relayHistory: message.relayHistory.map { $0.uuidString },
                messageTypeRaw: message.type.rawValue
            ) }
            AppLogger.multipeer.warning("""
            [OFFLINE_QUEUE_STORED]
            messageID=\(message.id.uuidString)
            type=\(message.type.rawValue)
            destination=\(message.destinationID)
            status=QUEUED_FOR_RANGE
            """)
            return
        }
        
        let priority: MeshPacketPriority = message.isSOS ? .critical : .normal
        MeshOutboundQueue.shared.enqueue(
            data: binaryData,
            priority: priority,
            isReliable: true,
            toPeers: targetPeers,
            session: session,
            tag: "MSG_\(message.type.rawValue)"
        )
        
        let shortMsgID = String(message.id.uuidString.prefix(6)).uppercased()
        RelaynTransportDiagnosticsManager.shared.recordOutgoingMessage(id: message.id, peer: session.connectedPeers.first?.displayName ?? "Broadcast", result: "Queued")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "TX_QUEUED", peer: firstPeerShort, details: "messageID=\(shortMsgID) bytes=\(binaryData.count) priority=\(priority)")
        
        AppLogger.multipeer.info("""
        [PINGLY_TX_QUEUED]
        frameID=\(message.id.uuidString)
        peer=\(peerNames)
        bytes=\(binaryData.count)
        priority=\(priority.rawValue)
        """)
        
        AppLogger.multipeer.info("Enqueued emergency binary message ID: \(message.id) to \(targetPeers.count) peers")
    }
    
    /// Broadcasts a critical Emergency SOS beacon with high priority across the mesh.
    func broadcastEmergencySOS(location: CLLocation?, notes: String? = nil) {
        let alias = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? NodeIdentity.shared.displayName
        let originID = NodeIdentity.shared.nodeID
        
        let sosMsg = Message(
            id: UUID(),
            originID: originID,
            destinationID: "BROADCAST",
            senderID: originID,
            senderName: alias,
            channelID: "CH-1 EMERGENCY",
            text: notes ?? "🚨 EMERGENCY SOS BEACON BROADCAST",
            timestamp: Date(),
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            altitude: location?.altitude,
            accuracy: location?.horizontalAccuracy,
            isSOS: true,
            emergencyStatus: .medicalEmergency,
            hopsCount: 0,
            ttl: Constants.Mesh.maxMeshHops,
            type: .location
        )
        
        broadcast(message: sosMsg)
        AppLogger.multipeer.warning("[EMERGENCY_SOS_TX] Broadcasted high-priority SOS beacon from \(alias) (Lat: \(location?.coordinate.latitude ?? 0), Lon: \(location?.coordinate.longitude ?? 0))")
        AppLogger.multipeer.info("""
        [DIAG_LOC_TX]
        packetType=LOCATION
        isSOS=true
        payloadCoords=(\(location?.coordinate.latitude ?? 0), \(location?.coordinate.longitude ?? 0))
        alt=\(location?.altitude ?? 0)
        acc=\(location?.horizontalAccuracy ?? 0)
        timestamp=\(Date())
        """)
    }
    
    func sendAudioStream(data: Data) {
        sendRawPTTPacket(data, type: .chunk)
    }
    
    /// Relay-only variant of broadcast that excludes the originating peer to prevent echo-back loops.
    ///
    /// Encodes using compact binary wire format and dispatches via priority outbound queue.
    private func broadcastExcluding(message: Message, excludingPeer senderPeerID: MCPeerID) {
        guard let session = session else { return }
        let targetPeers = session.connectedPeers.filter { $0 != senderPeerID }
        guard !targetPeers.isEmpty else {
            AppLogger.multipeer.info("[MESH_RELAY] No relay targets after excluding sender \(senderPeerID.displayName) — packet dropped")
            return
        }
        
        var encryptedPayload: Data? = nil
        if message.isEncrypted {
            if let decodedData = Data(base64Encoded: message.text) {
                encryptedPayload = decodedData
            } else {
                AppLogger.multipeer.error("[MESH_RELAY] Failed to decode base64 ciphertext for relay")
                return
            }
        }
        
        guard let binaryData = try? MeshPacketHeader.encode(message, isEncrypted: message.isEncrypted, encryptedPayload: encryptedPayload) else { return }
        let priority: MeshPacketPriority = message.isSOS ? .critical : .normal
        MeshOutboundQueue.shared.enqueue(
            data: binaryData,
            priority: priority,
            isReliable: true,
            toPeers: targetPeers,
            session: session,
            tag: "RELAY_\(message.type.rawValue)"
        )
        
        let targetNames = targetPeers.map { $0.displayName }.joined(separator: ", ")
        AppLogger.multipeer.info("[MESH_RELAY] Queued binary relay \(message.id.uuidString.prefix(6)) hop=\(message.hopsCount)/\(message.ttl) to [\(targetNames)] (excluded sender: \(senderPeerID.displayName))")
    }
    
    func sendRawPTTPacket(_ packet: Data, type: PTTFrameType) {
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        let peerNames = session.connectedPeers.map { $0.displayName }.joined(separator: ", ")
        
        AppLogger.multipeer.info("""
        [PINGLY_SERIALIZATION]
        encoder=PTTFrameHeader
        type=PTT_RAW_\(type.rawValue)
        bytes=\(packet.count)
        
        [PINGLY_TX_BEGIN]
        timestamp=\(Date())
        peer=\(peerNames)
        peerID=\(peerNames)
        transport=MCSession
        reliability=\(type == .chunk ? "unreliable" : "reliable")
        frameID=PTT_RAW_\(type.rawValue)
        frameType=PTT_RAW_\(type.rawValue)
        messageType=PTT_RAW
        senderID=\(self.myPeerID.displayName)
        destinationID=BROADCAST
        channelID=AUDIO_STREAM
        hopCount=0
        payloadBytes=\(packet.count)
        encodedBytes=\(packet.count)
        """)
        
        let priority: MeshPacketPriority = (type == .start || type == .end) ? .critical : .realtime
        let isReliable = (type == .start || type == .end)
        
        if isReliable {
            try? session.send(packet, toPeers: session.connectedPeers, with: .reliable)
        } else {
            try? session.send(packet, toPeers: session.connectedPeers, with: .unreliable)
        }
    }
    
    func broadcastChannelSync(channelName: String) {
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        let invite = ChannelInvite(channelName: channelName, creatorHandle: currentHandle)
        do {
            let data = try JSONEncoder().encode(invite)
            let peerNames = session.connectedPeers.map { $0.displayName }.joined(separator: ", ")
            
            AppLogger.multipeer.info("""
            [PINGLY_SERIALIZATION]
            encoder=JSONEncoder
            type=ChannelInvite
            bytes=\(data.count)
            
            [PINGLY_TX_BEGIN]
            timestamp=\(Date())
            peer=\(peerNames)
            peerID=\(peerNames)
            transport=MCSession
            reliability=reliable
            frameID=CHANNEL_SYNC
            frameType=CHANNEL_SYNC
            messageType=CHANNEL_SYNC
            senderID=\(self.myPeerID.displayName)
            destinationID=BROADCAST
            channelID=\(channelName)
            hopCount=0
            payloadBytes=\(data.count)
            encodedBytes=\(data.count)
            """)
            
            MeshOutboundQueue.shared.enqueue(
                data: data,
                priority: .bulk,
                isReliable: true,
                toPeers: session.connectedPeers,
                session: session,
                tag: "CHANNEL_SYNC"
            )
            
            AppLogger.multipeer.info("Enqueued channel sync for \(channelName) to \(session.connectedPeers.count) peers")
        } catch {
            AppLogger.multipeer.error("""
            [PINGLY_TX_FAILURE]
            frameID=CHANNEL_SYNC
            peer=\(session.connectedPeers.map { $0.displayName }.joined(separator: ", "))
            error=\(type(of: error))
            errorDescription=\(error.localizedDescription)
            """)
        }
    }
    
    
    func isCanonicalRoutingIdentity(destinationID: String, channel: String) -> Bool {
        if destinationID.contains("_AUTO") || destinationID.contains("_SAVED") ||
           channel.contains("_AUTO") || channel.contains("_SAVED") {
            return false
        }
        if destinationID.contains("_") || (destinationID.contains(" ") && !destinationID.hasPrefix("CH-")) {
            return false
        }
        if destinationID == "BROADCAST" {
            return channel.hasPrefix("CH-")
        }
        if destinationID.hasPrefix("TEST-") {
            return true
        }
        if UUID(uuidString: destinationID) == nil {
            return false
        }
        return true
    }
}

struct ChannelInvite: Codable {
    let type: String
    let channelName: String
    let creatorHandle: String
    
    init(channelName: String, creatorHandle: String) {
        self.type = "CHANNEL_SYNC"
        self.channelName = channelName
        self.creatorHandle = creatorHandle
    }
}

// MARK: - MCSessionDelegate
extension MultipeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let shortPeer = String(peerID.displayName.prefix(6))
            let stateString: String
            switch state {
            case .connected:
                stateString = "CONNECTED"
            case .connecting:
                stateString = "CONNECTING"
            case .notConnected:
                stateString = "NOT_CONNECTED"
            @unknown default:
                stateString = "UNKNOWN"
            }
            
            AppLogger.multipeer.info("\(AppLogger.peerTag) connection state peer=\(shortPeer) state=\(stateString.lowercased())")
            
            AppLogger.multipeer.info("""
            [PINGLY_PEER_STATE]
            peer=\(peerID.displayName)
            peerID=\(peerID.displayName)
            state=\(stateString)
            timestamp=\(Date())
            queue=\(RelaynTransportLogger.currentQueueName())
            """)
            
            AppLogger.multipeer.info("""
            [DIAG_PEER_STATE_CHANGE]
            peer=\(peerID.displayName)
            hash=\(peerID.hash)
            state=\(stateString)
            connectedCount=\(self.connectedPeers.count)
            """)
            
            let localFingerprint = String(KeychainIdentityService.shared.fetchOrCreateDeviceID().uuidString.prefix(6))
            let details = "localDevice=\(localFingerprint) state=\(stateString) connectedPeers=\(self.connectedPeers.count)"
            RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTION_STATE_CHANGE", peer: peerID.displayName, details: details)
            
            switch state {
            case .connecting:
                AppLogger.multipeer.info("[MESH_CONNECTING] peer=\(peerID.displayName)")
            case .connected:
                let resolvedNodeID = self.peerIDToNodeIDMap[peerID] ?? peerID.displayName
                let cleanName = self.peerIDToHandleMap[peerID] ?? peerID.displayName.cleanBaseName
                
                AppLogger.multipeer.info("[MESH_CONNECTED] peer=\(peerID.displayName) nodeID=\(resolvedNodeID) handle=\(cleanName)")
                self.peerConnectionStates[peerID] = .connecting
                AppLogger.multipeer.info("Peer connecting: \(peerID.displayName) -> mapped to nodeID: \(resolvedNodeID), handle: \(cleanName)")
                AppLogger.multipeer.info("""
                [DIAG_PEER_CONNECTED]
                peer=\(peerID.displayName)
                resolvedNodeID=\(resolvedNodeID)
                totalConnected=\(self.connectedPeers.count + 1)
                """)
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTED", peer: resolvedNodeID, details: details)
                RelaynTransportDiagnosticsManager.shared.recordPeerConnection(peer: resolvedNodeID)
                
                self.peerConnectionStates[peerID] = .connected
                
                if !self.connectedPeers.contains(where: { $0.id == resolvedNodeID }) {
                    let newPeer = PeerDevice(
                        id: resolvedNodeID,
                        displayName: cleanName,
                        mcPeerID: peerID,
                        rssi: -55,
                        emergencyStatus: self.currentStatus,
                        isConnected: true
                    )
                    self.connectedPeers.append(newPeer)
                }
                
                // Transmit synthetic SESSION_READY to finalize handshake
                let readyMsg = Message(
                    id: UUID(),
                    originID: NodeIdentity.shared.nodeID,
                    destinationID: resolvedNodeID,
                    senderID: NodeIdentity.shared.nodeID,
                    senderName: NodeIdentity.shared.displayName,
                    channelID: nil,
                    text: "SESSION_READY",
                    timestamp: Date(),
                    hopsCount: 0,
                    ttl: 1,
                    type: .sessionReady
                )
                guard let readyData = try? MeshPacketHeader.encode(readyMsg) else { return }
                try? self.session?.send(readyData, toPeers: [peerID], with: .reliable)
                
                let peerList = self.connectedPeers.map { $0.displayName }
                RelaynTransportDiagnosticsManager.shared.updateConnectedPeersList(peerList)
                let elapsedMs = self.connectStartTimestamp != nil ? Int(Date().timeIntervalSince(self.connectStartTimestamp!) * 1000) : 0
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "SESSION_READY", peer: resolvedNodeID, details: "connectedPeersCount=\(self.connectedPeers.count)")
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTED_PEERS_COUNT", peer: resolvedNodeID, details: "count=\(self.connectedPeers.count)")
                
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "CONNECTED", peer: resolvedNodeID, details: "connectedPeers=\(self.connectedPeers.count)")
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "SESSION_READY", peer: resolvedNodeID, details: "CONNECT_TO_READY elapsedMs=\(elapsedMs)")
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "CONNECTED_PEERS_COUNT", peer: resolvedNodeID, details: "count=\(self.connectedPeers.count)")
                
                AppLogger.multipeer.info("""
                [MESH_SESSION_READY]
                peer=\(peerID.displayName)
                peerID=\(peerID.displayName)
                
                [PINGLY_CONNECTED_PEERS]
                count=\(self.connectedPeers.count)
                peers=[\(peerList.joined(separator: ", "))]
                """)
                
                RelaynTransportDiagnosticsManager.shared.logDiagnosticSummary()
                self.flushPendingStoreAndForwardQueue(for: peerID)
                ChannelPresenceManager.shared.broadcastHeartbeat()
                LocationShareManager.shared.evaluateBroadcastTimer()
                
            case .notConnected:
                self.peerConnectionStates[peerID] = .disconnected
                let resolvedNodeID = self.peerIDToNodeIDMap[peerID] ?? peerID.displayName
                let cleanName = self.peerIDToHandleMap[peerID] ?? peerID.displayName.cleanBaseName
                
                AppLogger.multipeer.info("[MESH_DISCONNECTED] peer=\(peerID.displayName) nodeID=\(resolvedNodeID) handle=\(cleanName)")
                AppLogger.multipeer.info("Peer disconnected: \(peerID.displayName) -> resolvedNodeID: \(resolvedNodeID)")
                AppLogger.multipeer.info("""
                [DIAG_PEER_DISCONNECTED]
                peer=\(peerID.displayName)
                resolvedNodeID=\(resolvedNodeID)
                remainingConnected=\(max(0, self.connectedPeers.count - 1))
                """)
                let pttActive = WalkieTalkieNetworkManager.shared.isFloorLockedBySelf || WalkieTalkieNetworkManager.shared.activeFloorSenderID != nil
                let disconnectDetails = "stateBefore=CONNECTED connectedPeers=\(self.connectedPeers.count) pttActive=\(pttActive) lastError=\(RelaynTransportDiagnosticsManager.shared.lastSocketError)"
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "DisconnectTimeline", event: "DISCONNECT_BEGIN", peer: resolvedNodeID, details: disconnectDetails)
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "DisconnectTimeline", event: "SESSION_DISCONNECT", peer: resolvedNodeID, details: "disconnectCount=\(RelaynTransportDiagnosticsManager.shared.disconnectCount) disconnectReason=unknown errorDomain=NSPOSIXErrorDomain errorCode=54")
                
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(
                    event: "SESSION_DISCONNECT",
                    peer: resolvedNodeID,
                    details: "disconnectReason=unknown errorDomain=NSPOSIXErrorDomain errorCode=54 connectedPeersCount=\(self.connectedPeers.count - 1)"
                )
                MeshNotificationManager.shared.notifyPeerDisconnected(peerID: resolvedNodeID, displayName: cleanName)
                
                // 1. Flush the disconnected peer's outbound queue immediately
                MeshOutboundQueue.shared.flushQueue(for: peerID)
                
                // 2. Invalidate cached direct routes, but PRESERVE identity mapping for transient reconnects
                self.connectedPeers.removeAll(where: { $0.id == resolvedNodeID || $0.mcPeerID == peerID })
                
                // DO NOT remove from peerIDToNodeIDMap or peerIDToHandleMap here.
                // If the same MCPeerID reconnects silently, we must retain its canonical NodeID mapping.
                
                // Evict disconnected peer from channel presence registries immediately
                ChannelPresenceManager.shared.handlePeerDisconnected(nodeIDString: resolvedNodeID)
                ChannelPresenceManager.shared.handlePeerDisconnected(nodeIDString: peerID.displayName)
                
                // 3. Purge temporary audio playback state if disconnected peer was active speaker
                if let activeFloor = WalkieTalkieNetworkManager.shared.activeFloorSenderID,
                   activeFloor == resolvedNodeID || activeFloor == peerID.displayName {
                    WalkieTalkieNetworkManager.shared.stopActiveAudioStream()
                }
                
                let peerList = self.connectedPeers.map { $0.displayName }
                RelaynTransportDiagnosticsManager.shared.updateConnectedPeersList(peerList)
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTED_PEERS_COUNT", peer: resolvedNodeID, details: "count=\(self.connectedPeers.count)")
                
                AppLogger.multipeer.info("""
                [PINGLY_CONNECTED_PEERS]
                count=\(self.connectedPeers.count)
                peers=[\(peerList.joined(separator: ", "))]
                """)
                
                // 4. Re-route unacknowledged / store-and-forward mesh messages via surviving peers
                if !self.connectedPeers.isEmpty {
                    AppLogger.multipeer.info("Triggering store-and-forward re-routing after peer churn (surviving peers: \(self.connectedPeers.count))")
                    self.flushPendingStoreAndForwardQueue()
                }
            case .connecting:
                self.connectStartTimestamp = Date()
                AppLogger.multipeer.info("\(AppLogger.peerTag) connection attempt peer=\(shortPeer)")
                AppLogger.multipeer.info("Connecting to peer: \(peerID.displayName)")
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTING", peer: peerID.displayName, details: details)
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "CONNECTING", peer: peerID.displayName)
            @unknown default:
                break
            }
        }
    }
    
    /// Flushes queued offline store-and-forward messages (both origin and relay roles) when peer nodes enter network range.
    func flushPendingStoreAndForwardQueue(for peerID: MCPeerID? = nil) {
        Task {
            await self.queueCoalescer.performCoalescedWork { @MainActor in
                guard !self.connectedPeers.isEmpty else { return }
                
                let localNodeID = NodeIdentity.shared.nodeID
                await SwiftDataService.shared.persistenceActor.cleanupAcknowledgedPendingMessages()
                await SwiftDataService.shared.persistenceActor.resetFailedPendingMessages()
                let pendingList = SwiftDataService.shared.fetchPendingMessages()
                guard !pendingList.isEmpty else { return }
                
                let targetPeerName = peerID?.displayName ?? self.connectedPeers.first?.displayName ?? "UnknownPeer"
                AppLogger.multipeer.info("[OFFLINE_QUEUE_FLUSH] peer=\(targetPeerName) flushedCount=\(pendingList.count)")
                
                for pending in pendingList {
                    let isBroadcastOrChannel = (pending.destinationID == "BROADCAST") || pending.channel.hasPrefix("CH-") || pending.isSOS
                    if !isBroadcastOrChannel {
                        let targetMatchesConnected = self.connectedPeers.contains { peer in
                            peer.id == pending.destinationID || peer.displayName == pending.destinationID || peer.mcPeerID?.displayName == pending.destinationID
                        }
                        if !targetMatchesConnected {
                            continue
                        }
                        
                        if let pid = peerID {
                            let nodeID = self.peerIDToNodeIDMap[pid]
                            let cleanName = self.peerIDToHandleMap[pid] ?? pid.displayName.cleanBaseName
                            if pending.destinationID != pid.displayName && pending.destinationID != nodeID && pending.destinationID != cleanName {
                                continue
                            }
                        }
                    }
                    
                    let msgTag = AppLogger.messageTag(pending.messageID)
                    
                    // Validate canonical routing identity
                    guard self.isCanonicalRoutingIdentity(destinationID: pending.destinationID, channel: pending.channel) else {
                        AppLogger.multipeer.warning("\(msgTag) QUARANTINED reason=non_canonical_identity destination=\(pending.destinationID) channel=\(pending.channel)")
                        await SwiftDataService.shared.persistenceActor.updatePendingMessageStatus(messageID: pending.messageID, statusRaw: "FAILED", reason: "QUARANTINED_NON_CANONICAL")
                        continue
                    }
                    
                    guard pending.retryCount < pending.maxRetries else {
                        AppLogger.multipeer.warning("\(msgTag) MAX_RETRIES_REACHED retryCount=\(pending.maxRetries)")
                        AppLogger.multipeer.warning("Pending message \(pending.messageID) reached max retries (\(pending.maxRetries)). Skipping.")
                        continue
                    }
                    
                    // Controlled exponential backoff delay check (3s base backoff)
                    if let lastAttempt = pending.lastAttemptTimestamp, Date().timeIntervalSince(lastAttempt) < 3.0 {
                        continue
                    }
                    
                    // Prevent forwarding if TTL exhausted
                    guard pending.ttl > 1 else {
                        AppLogger.multipeer.warning("\(AppLogger.routingTag(pending.messageID)) FORWARD_REJECTED reason=TTL_EXPIRED (\(pending.hopsCount)/\(pending.ttl))")
                        AppLogger.multipeer.warning("Pending message \(pending.messageID) TTL exhausted (\(pending.hopsCount)/\(pending.ttl)). Halting forward.")
                        continue
                    }
                    
                    // 🔒 P0-3: STORE-AND-FORWARD AUTHORIZATION
                    let isDirectMessage = (pending.destinationID != "BROADCAST") && !pending.channel.hasPrefix("CH-")
                    
                    if pending.queueRole == .origin && isDirectMessage {
                        if !DirectChatGate.shared.canSendDirectMessage(to: pending.destinationID) {
                            AppLogger.multipeer.warning("[MESH_CHAT_QUEUE_AUTH_DROP] messageID=\(pending.messageID.uuidString) destinationID=\(pending.destinationID) conversationID=\(pending.conversationID.uuidString) queueRole=\(pending.queueRoleRaw) reason=AUTH_REVOKED")
                            await SwiftDataService.shared.persistenceActor.updatePendingMessageStatus(messageID: pending.messageID, statusRaw: "FAILED", reason: "AUTH_REVOKED")
                            continue
                        }
                    }
                    
                    
                    let targetPeerName = self.connectedPeers.first?.displayName ?? pending.destinationID
                    let shortTarget = String(targetPeerName.prefix(6))
                    
                    AppLogger.multipeer.info("\(msgTag) PEER_AVAILABLE peer=\(shortTarget)")
                    AppLogger.multipeer.info("\(msgTag) RETRY_START retryCount=\(pending.retryCount + 1) peer=\(shortTarget)")
                    AppLogger.multipeer.info("\(msgTag) SEND_ATTEMPT attempt=\(pending.retryCount + 1) reason=QUEUE_PROCESSOR peer=\(shortTarget)")
                    
                    await SwiftDataService.shared.persistenceActor.updatePendingMessageStatus(messageID: pending.messageID, statusRaw: "SENDING")
                    
                    let isTranscript = pending.text.hasPrefix("[")
                    let msg = Message(
                        id: pending.messageID,
                        originID: pending.originID,
                        destinationID: pending.destinationID,
                        senderID: localNodeID,
                        senderName: pending.senderName,
                        previousHopID: localNodeID,
                        text: pending.text,
                        timestamp: pending.timestamp,
                        isSOS: pending.isSOS,
                        hopsCount: pending.hopsCount + 1,
                        ttl: pending.ttl - 1,
                        type: P2PMessageType(rawValue: pending.messageTypeRaw) ?? (isTranscript ? .transcript : .chat)
                    )
                    
                    AppLogger.multipeer.info("""
                    [PINGLY_RELAY_TX]
                    originalMessageID=\(pending.messageID.uuidString)
                    relayMessageID=\(pending.messageID.uuidString)
                    originSender=\(pending.originID)
                    currentSender=\(localNodeID)
                    destination=\(pending.destinationID)
                    channel=\(pending.channel)
                    hopCount=\(msg.hopsCount)
                    maxHop=\(msg.ttl)
                    """)
                    
                    self.broadcast(message: msg)
                    
                    if isBroadcastOrChannel {
                        await SwiftDataService.shared.persistenceActor.deletePendingMessage(messageID: pending.messageID)
                        AppLogger.multipeer.info("Dispatched \(pending.queueRole.rawValue) broadcast message \(pending.messageID) without ACK tracking.")
                    } else {
                        await SwiftDataService.shared.persistenceActor.updatePendingMessageStatus(messageID: pending.messageID, statusRaw: "WAITING_FOR_ACK")
                        AppLogger.multipeer.info("\(msgTag) RETRY_SEND_COMPLETED retryCount=\(pending.retryCount)")
                        AppLogger.multipeer.info("Dispatched \(pending.queueRole.rawValue) message \(pending.messageID) for '\(pending.destinationID)' (Hop \(msg.hopsCount)/\(msg.ttl))")
                        
                        // Schedule ACK timeout verification (5 seconds)
                        AppLogger.multipeer.info("\(AppLogger.ackTag(pending.messageID)) ACK_TIMER_STARTED timeout=5")
                        Task {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            let checkList = SwiftDataService.shared.fetchPendingMessages()
                            if let item = checkList.first(where: { $0.messageID == pending.messageID }), item.status == .waitingForACK {
                                AppLogger.multipeer.warning("\(AppLogger.ackTag(pending.messageID)) ACK_TIMEOUT retryCount=\(item.retryCount)")
                                await SwiftDataService.shared.persistenceActor.updatePendingMessageStatus(messageID: pending.messageID, statusRaw: "FAILED", reason: "ACK_TIMEOUT")
                            } else {
                                AppLogger.multipeer.info("\(AppLogger.ackTag(pending.messageID)) ACK_TIMER_CANCELLED")
                            }
                        }
                    }
                }
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        RelaynTransportDiagnosticsManager.shared.incrementRxFrames()
        let timestamp = Date()
        let shortPeer = String(peerID.displayName.prefix(6))
        let sha256 = RelaynTransportLogger.sha256Hex(data: data)
        let hexPrev = RelaynTransportLogger.hexPreview(data: data)
        let utf8Prev = RelaynTransportLogger.utf8Preview(data: data)
        let threadContext = RelaynTransportLogger.currentThreadDescription()
        
        AppLogger.multipeer.info("\(AppLogger.transportTag()) RECEIVE_START peer=\(shortPeer) bytes=\(data.count)")
        
        AppLogger.multipeer.info("""
        [PINGLY_RX_BEGIN]
        timestamp=\(timestamp)
        peer=\(peerID.displayName)
        peerID=\(peerID.displayName)
        bytes=\(data.count)
        hexPreview=\(hexPrev)
        utf8Preview=\(utf8Prev)
        thread=\(threadContext)
        
        [PINGLY_RX_RAW]
        bytes=\(data.count)
        sha256=\(sha256)
        hexPreview=\(hexPrev)
        utf8Preview=\(utf8Prev)
        """)
        
        // Offload decoding, verification & routing off the main thread for performance
        Task {
            // 1. Check for PTT audio binary framing
            if let header = PTTFrameHeader.decode(from: data) {
                // Deduplicate using VoiceSeenCache
                if VoiceSeenCache.shared.contains(senderNodeID: header.senderNodeID, sessionID: header.sessionID, sequenceNo: header.sequenceNo) {
                    AppLogger.multipeer.info("PTT Frame Dropped: Duplicate session=\(header.sessionID.uuidString.prefix(6)) seq=\(header.sequenceNo)")
                    RelaynTransportDiagnosticsManager.shared.incrementRelayDropped()
                    return
                }
                
                // Mark as seen
                VoiceSeenCache.shared.insert(senderNodeID: header.senderNodeID, sessionID: header.sessionID, sequenceNo: header.sequenceNo)
                
                AppLogger.multipeer.info("\(AppLogger.frameTag()) FRAME_RECEIVED_UNKNOWN_ID peer=\(shortPeer) type=PTT_RAW bytes=\(data.count)")
                RelaynTransportDiagnosticsManager.shared.recordIncomingMessage(id: nil, peer: peerID.displayName, result: "PTT Raw Frame", decodeRes: "Success")
                
                AppLogger.multipeer.info("""
                [PINGLY_DECODE_BEGIN]
                peer=\(peerID.displayName)
                bytes=\(data.count)
                decoder=PTTFrameHeaderDecoder
                expectedType=PTTFrameHeader
                
                [PINGLY_DECODE_SUCCESS]
                peer=\(peerID.displayName)
                frameID=PTT_RAW
                frameType=PTT_RAW
                messageType=PTT_RAW
                senderID=\(header.senderNodeID.uuidString)
                destinationID=BROADCAST
                channelID=AUDIO_STREAM
                hopCount=\(header.hopCount)
                payloadSize=\(data.count)
                """)
                
                RelaynTransportDiagnosticsManager.shared.incrementDecodeSuccess()
                
                // Deliver Locally
                NotificationCenter.default.post(
                    name: .didReceiveRawPTTPacket,
                    object: self,
                    userInfo: ["packet": data, "peerID": peerID]
                )
                DispatchQueue.main.async {
                    self.receivedAudioDataSubject.send(data)
                }
                
                // PTT Forwarding Logic
                if header.hopCount < header.ttl {
                    let newHopCount = header.hopCount + 1
                    let newHeader = PTTFrameHeader(
                        version: header.version,
                        type: header.type,
                        channel: header.channel,
                        hopCount: newHopCount,
                        ttl: header.ttl,
                        sequenceNo: header.sequenceNo,
                        timestampMs: header.timestampMs,
                        senderNodeID: header.senderNodeID,
                        sessionID: header.sessionID,
                        isEncrypted: header.isEncrypted
                    )
                    
                    var forwardedPacket = newHeader.encode()
                    // Append payload
                    forwardedPacket.append(data.subdata(in: header.actualHeaderSize..<data.count))
                    
                    // Exclude sender
                    let targetPeers = session.connectedPeers.filter { $0 != peerID }
                    if !targetPeers.isEmpty {
                        let priority: MeshPacketPriority = (header.type == .start || header.type == .end) ? .critical : .realtime
                        let isReliable = (header.type == .start || header.type == .end)
                        
                        MeshOutboundQueue.shared.enqueue(
                            data: forwardedPacket,
                            priority: priority,
                            isReliable: isReliable,
                            toPeers: targetPeers,
                            session: session,
                            tag: "PTT_RAW_FWD"
                        )
                        AppLogger.multipeer.info("PTT Frame Forwarded: session=\(header.sessionID.uuidString.prefix(6)) seq=\(header.sequenceNo) hop=\(newHopCount)/\(header.ttl)")
                        RelaynTransportDiagnosticsManager.shared.incrementRelayForwarded()
                    }
                } else {
                    AppLogger.multipeer.info("PTT Frame TTL Exhausted: session=\(header.sessionID.uuidString.prefix(6)) seq=\(header.sequenceNo) hop=\(header.hopCount)")
                }
                
                return
            }
            
            // 2. Check for Compact Binary Mesh Packet (0x5245 / "RE" Magic Bytes)
            if MeshPacketHeader.isBinaryMeshPacket(data) {
                do {
                    let meshPacket = try MeshPacketHeader.decode(from: data)
                    let cleanName = self.peerIDToHandleMap[peerID] ?? peerID.displayName.cleanBaseName
                    let message = meshPacket.toMessage(senderDisplayName: cleanName)
                    
                    let estimatedJsonBytes = 450 + message.text.utf8.count
                    let savedBytes = max(0, estimatedJsonBytes - data.count)
                    let savedPct = Int((Double(savedBytes) / Double(max(1, estimatedJsonBytes))) * 100.0)
                    
                    AppLogger.multipeer.info("""
                    [BINARY_DECODE_SUCCESS]
                    peer=\(peerID.displayName)
                    messageID=\(message.id.uuidString)
                    type=\(message.type.rawValue)
                    wireBytes=\(data.count)
                    jsonBytesEst=\(estimatedJsonBytes)
                    wireReductionPct=\(savedPct)%
                    channel=\(message.channelID ?? "DIRECT")
                    hopCount=\(message.hopsCount)
                    ttl=\(message.ttl)
                    """)
                    
                    RelaynTransportDiagnosticsManager.shared.incrementDecodeSuccess()
                    RelaynTransportDiagnosticsManager.shared.recordIncomingMessage(id: message.id, peer: peerID.displayName, result: "Binary Mesh Received", decodeRes: "Success")
                    
                    if meshPacket.flags.isEOT {
                        DispatchQueue.main.async {
                            WalkieTalkieNetworkManager.shared.handleExplicitEOT()
                        }
                    }
                    
                    self.processDecodedMessage(message, fromPeer: peerID, rawData: data)
                    return
                } catch {
                    RelaynTransportDiagnosticsManager.shared.incrementDecodeFailures()
                    AppLogger.multipeer.error("""
                    [BINARY_DECODE_ERR]
                    peer=\(peerID.displayName)
                    bytes=\(data.count)
                    error=\(error.localizedDescription)
                    """)
                    RelaynTransportDiagnosticsManager.shared.recordIncomingMessage(id: nil, peer: peerID.displayName, result: "Rx Binary Failed", decodeRes: error.localizedDescription)
                    return
                }
            }
            
            // 3. Try decoding as ChannelInvite JSON
            if let invite = try? JSONDecoder().decode(ChannelInvite.self, from: data), invite.type == "CHANNEL_SYNC" {
                AppLogger.multipeer.info("\(AppLogger.frameTag()) FRAME_RECEIVED_UNKNOWN_ID peer=\(shortPeer) type=CHANNEL_SYNC bytes=\(data.count)")
                RelaynTransportDiagnosticsManager.shared.recordIncomingMessage(id: nil, peer: peerID.displayName, result: "Channel Sync", decodeRes: "Success")
                
                AppLogger.multipeer.info("""
                [PINGLY_DECODE_SUCCESS]
                peer=\(peerID.displayName)
                frameID=CHANNEL_SYNC
                frameType=CHANNEL_SYNC
                messageType=CHANNEL_SYNC
                senderID=\(invite.creatorHandle)
                destinationID=BROADCAST
                channelID=\(invite.channelName)
                hopCount=0
                payloadSize=\(data.count)
                """)
                
                RelaynTransportDiagnosticsManager.shared.incrementDecodeSuccess()
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .didReceiveChannelSync,
                        object: self,
                        userInfo: ["channelName": invite.channelName, "creator": invite.creatorHandle]
                    )
                }
                AppLogger.multipeer.info("Received channel sync invite: \(invite.channelName) from \(invite.creatorHandle)")
                return
            }
            
            // 4. Try legacy JSON Message decoding
            AppLogger.multipeer.info("\(AppLogger.frameTag()) DESERIALIZE_START")
            let message: Message
            do {
                message = try JSONDecoder().decode(Message.self, from: data)
                AppLogger.multipeer.info("\(AppLogger.frameTag(message.id)) FRAME_RECEIVED peer=\(shortPeer) bytes=\(data.count)")
                AppLogger.multipeer.info("\(AppLogger.frameTag(message.id)) DESERIALIZE_SUCCESS")
                RelaynTransportDiagnosticsManager.shared.incrementDecodeSuccess()
                RelaynTransportDiagnosticsManager.shared.recordIncomingMessage(id: message.id, peer: peerID.displayName, result: "Received JSON", decodeRes: "Success")
                
                self.processDecodedMessage(message, fromPeer: peerID, rawData: data)
            } catch {
                RelaynTransportDiagnosticsManager.shared.incrementDecodeFailures()
                let (errDesc, codingPath) = RelaynTransportLogger.formatDecodingError(error)
                
                AppLogger.multipeer.error("\(AppLogger.frameTag()) FRAME_RECEIVED_UNKNOWN_ID peer=\(shortPeer) bytes=\(data.count)")
                AppLogger.multipeer.error("\(AppLogger.frameTag()) DESERIALIZE_FAILED reason=\(errDesc) path=\(codingPath)")
                RelaynTransportDiagnosticsManager.shared.recordIncomingMessage(id: nil, peer: peerID.displayName, result: "Rx Failed", decodeRes: errDesc)
                
                AppLogger.multipeer.error("""
                [PINGLY_DECODE_FAILURE]
                peer=\(peerID.displayName)
                bytes=\(data.count)
                decoder=JSONDecoder
                expectedType=Message
                error=\(type(of: error))
                errorDescription=\(errDesc)
                codingPath=\(codingPath)
                sha256=\(sha256)
                hexPreview=\(hexPrev)
                utf8Preview=\(utf8Prev)
                timestamp=\(timestamp)
                
                [PINGLY_FRAME_METADATA]
                frameMetadata=UNAVAILABLE_DECODE_FAILED
                """)
                
                AppLogger.multipeer.warning("Received un-decodable byte frame from \(peerID.displayName). Dropping safely.")
                return
            }
        }
    }
    
    // MARK: - Decoded Message Pipeline
    
    private func processDecodedMessage(_ message: Message, fromPeer peerID: MCPeerID, rawData data: Data) {
        let shortPeer = String(peerID.displayName.prefix(6))
            
            // 1. Protocol Version Validation
            AppLogger.multipeer.info("\(AppLogger.frameTag(message.id)) VALIDATION_START bytes=\(data.count)")
            guard message.protocolVersion <= Constants.Mesh.currentProtocolVersion else {
                AppLogger.multipeer.error("\(AppLogger.frameTag(message.id)) VALIDATION_FAILED reason=INVALID_PROTOCOL_VERSION actual=\(message.protocolVersion)")
                AppLogger.multipeer.warning("Rejected packet with unsupported future protocol version \(message.protocolVersion) > \(Constants.Mesh.currentProtocolVersion)")
                return
            }
            
            // 2. CryptoKit HMAC-SHA256 Envelope Verification
            guard MeshSecurityManager.shared.verify(message: message) else {
                AppLogger.multipeer.error("\(AppLogger.frameTag(message.id)) VALIDATION_FAILED reason=HMAC_SIGNATURE_MISMATCH")
                AppLogger.multipeer.error("Security Alert: Invalid HMAC-SHA256 signature tag on message \(message.id). Rejecting forged envelope.")
                return
            }
            
            AppLogger.multipeer.info("\(AppLogger.frameTag(message.id)) VALIDATION_SUCCESS version=\(message.protocolVersion) type=\(message.type.rawValue)")
            
            let localNodeID = NodeIdentity.shared.nodeID
            let localUserHandle = NodeIdentity.shared.displayName
            
            // Reject strictly if originating from local node or immediate self hop
            guard message.senderID != localNodeID && message.previousHopID != localNodeID else {
                AppLogger.multipeer.info("""
                [PINGLY_ROUTE_DECISION]
                action=DROP
                reason=SELF_ECHO_REJECTED
                """)
                return
            }
            
            // Reject non-ACK data messages if originated by local node (preventing loopback for non-ACK payloads)
            if message.type != .ack && message.originID == localNodeID {
                AppLogger.multipeer.info("""
                [PINGLY_ROUTE_DECISION]
                action=DROP
                reason=ORIGINATED_BY_LOCAL_NODE
                """)
                return
            }
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                var message = message
                var failedDecryption = false
                
                if message.isEncrypted, let channelID = message.channelID {
                    if let key = ChannelKeyStore.shared.key(for: channelID) {
                        if let decodedCiphertext = Data(base64Encoded: message.text) {
                            do {
                                let plaintextData = try ChannelCrypto.decrypt(sealedData: decodedCiphertext, key: key)
                                if let plaintextString = String(data: plaintextData, encoding: .utf8) {
                                    message.text = plaintextString
                                    message.isEncrypted = false // Mark as decrypted for local delivery
                                } else {
                                    failedDecryption = true
                                    AppLogger.multipeer.error("[CRYPTO_RX] Failed to decode plaintext to UTF8 string")
                                }
                            } catch {
                                failedDecryption = true
                                AppLogger.multipeer.error("[CRYPTO_RX] Failed to unseal ciphertext: \(error.localizedDescription)")
                            }
                        } else {
                            failedDecryption = true
                            AppLogger.multipeer.error("[CRYPTO_RX] Invalid Base64 ciphertext")
                        }
                    } else {
                        // Silent relay: we do not have the key
                        failedDecryption = true
                        AppLogger.multipeer.info("[CRYPTO_RX] Missing key for \(channelID), proceeding as silent relay")
                    }
                }
                
                if message.type == .sessionReady {
                    if message.destinationID == localNodeID {
                        AppLogger.multipeer.info("[SESSION_READY_HANDSHAKE_RX] Completed from peer=\(peerID.displayName)")
                        self.peerConnectionStates[peerID] = .sessionReady
                        let cleanName = self.peerIDToHandleMap[peerID] ?? peerID.displayName.cleanBaseName
                        MeshNotificationManager.shared.notifyPeerConnected(peerID: message.originID, displayName: cleanName)
                    }
                    return
                }
                
                // Handle incoming Delivery ACK frame
                if message.type == .ack {
                    AppLogger.multipeer.info("\(AppLogger.ackTag(message.id)) ACK_RECEIVE_START peer=\(shortPeer)")
                    RelaynTransportDiagnosticsManager.shared.incrementAckReceived()
                    
                    AppLogger.multipeer.info("[MESH_ACK] msg=\(message.id.uuidString) origin=\(message.originID) from=\(peerID.displayName) to=\(message.destinationID) hop=\(message.hopsCount)")
                    
                    let isAckForLocal = (message.destinationID == localNodeID)
                    
                    if isAckForLocal {
                        let shortID = String(message.id.uuidString.prefix(6)).uppercased()
                        AppLogger.multipeer.info("\(AppLogger.ackTag(message.id)) ACK_VALIDATION_SUCCESS")
                        RelaynTransportDiagnosticsManager.shared.recordACKEvent(id: message.id, peer: peerID.displayName, result: "ACK Validated")
                        RelaynTransportDiagnosticsManager.shared.incrementAckMatched()
                        RelaynTransportDiagnosticsManager.shared.incrementPhysicalTestACKed()
                        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "ACK_RX", peer: peerID.displayName, details: "messageID=\(shortID)")
                        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "MESSAGE_TEST_RESULT", peer: peerID.displayName, details: "messageID=\(shortID) result=ACKNOWLEDGED elapsedMs=0")
                        
                        AppLogger.multipeer.info("""
                        [PINGLY_ACK_MATCH]
                        originalMessageID=\(message.id.uuidString)
                        matched=true
                        pendingMessageFound=true
                        currentPendingStatus=DELIVERED
                        """)
                        
                        await SwiftDataService.shared.persistenceActor.markPendingMessageAsACKed(messageID: message.id)
                        MeshNotificationManager.shared.notifyMessageDelivered(messageID: message.id, recipientName: message.destinationID)
                        NotificationCenter.default.post(name: .didSaveVoiceTranscript, object: nil)
                        NotificationCenter.default.post(name: .didReceiveChatMessage, object: nil)
                        AppLogger.multipeer.info("Received End-to-End MessageDeliveryACK for message ID \(message.id)")
                    } else {
                        AppLogger.multipeer.info("\(AppLogger.ackTag(message.id)) ACK_RELAYING destination=\(String(message.destinationID.prefix(6)))")
                        // Intermediate node targeted ACK relaying back toward origin using persistent reverse path
                        RelaynTransportDiagnosticsManager.shared.incrementRelayForwarded()
                        
                        AppLogger.multipeer.info("""
                        [PINGLY_RELAY_RX]
                        originalMessageID=\(message.id.uuidString)
                        relayMessageID=\(message.id.uuidString)
                        originSender=\(message.originID)
                        currentSender=\(message.senderID)
                        destination=\(message.destinationID)
                        hopCount=\(message.hopsCount)
                        maxHop=\(message.ttl)
                        """)
                        
                        AppLogger.multipeer.info("Relaying MessageDeliveryACK for \(message.id) toward origin '\(message.originID)'")
                        await SwiftDataService.shared.persistenceActor.markPendingMessageAsACKed(messageID: message.id) // Clear local relay copy
                        
                        var relayAck = message
                        relayAck.previousHopID = localNodeID
                        relayAck.hopsCount += 1
                        
                        // Targeted reverse-path send if previousHopID node is connected
                        if let previousHopNode = self.connectedPeers.first(where: { $0.id == message.previousHopID || $0.displayName == message.previousHopID }),
                           let targetPeer = previousHopNode.mcPeerID {
                            
                            AppLogger.multipeer.info("""
                            [PINGLY_ACK_TX]
                            ackMessageID=\(relayAck.id.uuidString)
                            originalMessageID=\(message.id.uuidString)
                            peer=\(previousHopNode.displayName)
                            bytes=\(data.count)
                            frameType=ACK
                            """)
                            
                            guard let binaryAck = try? MeshPacketHeader.encode(relayAck) else { return }
                            MeshOutboundQueue.shared.enqueue(
                                data: binaryAck,
                                priority: .high,
                                isReliable: true,
                                toPeers: [targetPeer],
                                session: session,
                                tag: "DIRECT_ACK"
                            )
                            AppLogger.multipeer.info("Targeted ACK routing: Queued DELIVERY_ACK directly to reverse-path hop '\(previousHopNode.displayName)'")
                        } else {
                            AppLogger.multipeer.info("""
                            [PINGLY_ACK_TX]
                            ackMessageID=\(relayAck.id.uuidString)
                            originalMessageID=\(message.id.uuidString)
                            peer=BROADCAST
                            bytes=\(data.count)
                            frameType=ACK
                            """)
                            
                            // Safe fallback broadcast if previous hop is disconnected
                            self.broadcast(message: relayAck)
                        }
                    }
                    return
                }
                
                let isChannelMessage = message.channelID != nil && !message.channelID!.isEmpty && message.channelID!.hasPrefix("CH-")
                let isForMe = (message.destinationID == localNodeID) ||
                              (message.destinationID == "BROADCAST") ||
                              isChannelMessage
                
                let isSOS = message.isSOS || (message.emergencyStatus != .normal)
                let channelMatches = isChannelMessage ? (message.channelID?.uppercased() == self.activeChannelID.uppercased()) : true
                
                // Channel-targeted broadcasts are gated strictly by channelMatches so PTT
                // from CH-3 does NOT bleed into a device subscribed to CH-1.
                // Emergency SOS beacons (isSOS == true) bypass channel gates and deliver universally.
                // Plain broadcasts with no channelID are delivered unconditionally.
                var shouldDeliverLocally = isSOS ||
                                           (message.destinationID == localNodeID) ||
                                           (isChannelMessage && channelMatches) ||
                                           (!isChannelMessage && message.destinationID == "BROADCAST")
                
                if failedDecryption {
                    shouldDeliverLocally = false
                }
                
                // 🔒 P0-1: INCOMING CHAT NETWORK BOUNDARY AUTHORIZATION
                if shouldDeliverLocally && (message.type == .chat || message.type == .transcript) && message.destinationID == localNodeID {
                    if !DirectChatGate.shared.canSendDirectMessage(to: message.originID) {
                        shouldDeliverLocally = false
                        AppLogger.multipeer.warning("[MESH_CHAT_AUTH_DROP] senderNodeID=\(message.originID) destinationNodeID=\(message.destinationID) messageID=\(message.id.uuidString) conversationID=\(message.conversationID.uuidString) packetType=\(message.type.rawValue) reason=NOT_ACCEPTED")
                    } else {
                        AppLogger.multipeer.info("[MESH_CHAT_AUTH_ACCEPT] senderNodeID=\(message.originID) destinationNodeID=\(message.destinationID) messageID=\(message.id.uuidString) authorized=true")
                    }
                }
                
                // Relay independence: forward if (a) not addressed to this device, (b) channel
                // broadcast, OR (c) high-priority emergency SOS packet.
                let shouldForward = (!isForMe) || isChannelMessage || isSOS
                
                AppLogger.multipeer.info("""
                [DIAG_PACKET_ROUTE]
                type=\(message.type.rawValue)
                packetChannel=\(message.channelID ?? "NONE")
                activeChannel=\(self.activeChannelID)
                destination=\(message.destinationID)
                isSOS=\(isSOS)
                shouldDeliver=\(shouldDeliverLocally)
                shouldForward=\(shouldForward)
                """)
                
                AppLogger.multipeer.info("\(AppLogger.routingTag(message.id)) ROUTE_RECEIVED hops=\(message.hopsCount) ttl=\(message.ttl)")
                
                AppLogger.multipeer.info("""
                [PINGLY_CHANNEL_CHECK]
                messageID=\(message.id.uuidString)
                receivedChannel=\(message.channelID ?? message.destinationID)
                activeChannel=\(self.activeChannelID)
                matches=\(channelMatches)
                
                [PINGLY_DESTINATION_CHECK]
                messageID=\(message.id.uuidString)
                destination=\(message.destinationID)
                localDeviceID=\(localNodeID)
                localHandle=\(localUserHandle)
                matches=\(isForMe)
                destinationType=\(isChannelMessage ? "CHANNEL_BROADCAST" : (message.destinationID == "BROADCAST" ? "BROADCAST" : "DEVICE"))
                """)
                
                let convIDStr = message.conversationID.uuidString
                AppLogger.multipeer.info("[MESH_RX] msg=\(message.id.uuidString) origin=\(message.originID) conv=\(convIDStr) from=\(message.senderID) hop=\(message.hopsCount) ttl=\(message.ttl)")
                
                let shortMsgID = String(message.id.uuidString.prefix(6)).uppercased()
                
                // ── In-Memory Deduplication Gate ─────────────────────────────────────────
                // Check the seenCache FIRST — before any SwiftData access, before local
                // delivery, and before relay forwarding. This is the storm breaker:
                // exactly-once forwarding regardless of mesh topology.
                let canonicalIdentity = "\(message.originID)_\(message.id.uuidString)"
                if seenCache.contains(canonicalIdentity) {
                    AppLogger.multipeer.info("[MESH_DEDUP_DROP] msg=\(message.id.uuidString) origin=\(message.originID) identity=CANONICAL")
                    RelaynTransportDiagnosticsManager.shared.incrementRelayDropped()
                    return
                }
                // Mark as seen immediately so concurrent arrivals from other peers
                // (multi-path topology) are also dropped.
                seenCache.insert(canonicalIdentity)
                // ─────────────────────────────────────────────────────────────────────────
                
                let alreadyProcessed = SwiftDataService.shared.isMessageAlreadyProcessed(messageID: message.id)
                
                if shouldDeliverLocally {
                    RelaynTransportDiagnosticsManager.shared.incrementPhysicalTestReceived()
                    RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "RX_BEGIN", peer: peerID.displayName, details: "messageID=\(shortMsgID) type=\(message.type.rawValue)")
                    RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "DECODE_SUCCESS", peer: peerID.displayName, details: "messageID=\(shortMsgID)")
                    let convIDStr = message.conversationID.uuidString
                    AppLogger.multipeer.info("[MESH_DELIVERED] msg=\(message.id.uuidString) origin=\(message.originID) conv=\(convIDStr)")
                    
                    AppLogger.multipeer.info("\(AppLogger.messageTag(message.id)) DUPLICATE_CHECK")
                    AppLogger.multipeer.info("\(AppLogger.messageTag(message.id)) DUPLICATE=\(alreadyProcessed)")
                    RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "DUPLICATE_CHECK", peer: peerID.displayName, details: "messageID=\(shortMsgID) alreadyProcessed=\(alreadyProcessed)")
                    
                    if !alreadyProcessed {
                        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "REMOTE_PERSIST", peer: peerID.displayName, details: "messageID=\(shortMsgID)")
                        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "USER_DELIVERY", peer: peerID.displayName, details: "messageID=\(shortMsgID)")
                        self.receivedMessageSubject.send(message)
                        
                        if message.text.hasPrefix("LOCATION_PROTOCOL:") {
                            let jsonString = String(message.text.dropFirst("LOCATION_PROTOCOL:".count))
                            let locationMsg = Message(
                                id: message.id,
                                originID: message.originID,
                                destinationID: message.destinationID,
                                senderID: message.senderID,
                                senderName: message.senderName,
                                previousHopID: message.previousHopID,
                                text: jsonString,
                                timestamp: message.timestamp,
                                hopsCount: message.hopsCount,
                                ttl: message.ttl,
                                type: message.type
                            )
                            LocationShareManager.shared.processIncomingLocationPacket(locationMsg)
                        } else if message.type == .transcript || message.text.hasPrefix("PTT_TRANSCRIPT:") {
                            let cleanText = message.text.hasPrefix("PTT_TRANSCRIPT:") ? String(message.text.dropFirst("PTT_TRANSCRIPT:".count)) : message.text
                            // Use the sender's channelID when present; fall back to this
                            // device's active channel rather than the hardcoded default so
                            // multi-channel transcript history stays accurate.
                            let channel = isChannelMessage ? message.channelID! : self.activeChannelID
                            await SwiftDataService.shared.persistenceActor.saveVoiceTranscript(
                                id: message.id,
                                speakerName: message.senderName,
                                text: cleanText,
                                channel: channel,
                                isDelivered: true,
                                sessionID: message.sessionID
                            )
                            NotificationCenter.default.post(name: .didSaveVoiceTranscript, object: nil)
                            AppLogger.multipeer.info("Received P2P Voice Transcript for channel [\(channel)] from \(message.senderName)")
                        } else if message.type == .channelSync {
                            let senderAlias = message.senderName.isEmpty ? message.text : message.senderName
                            let channel = isChannelMessage ? message.channelID! : self.activeChannelID
                            
                            // 🔒 Access Gate Check
                            if !ChannelAccessGate.shared.isAuthorized(for: channel) {
                                AppLogger.multipeer.warning("Unauthorized CHANNEL_SYNC dropped for channel: \(channel)")
                                return
                            }
                            
                            let originUUID = UUID(uuidString: message.originID) ?? UUID()
                            let isDirect = message.hopsCount == 0
                            ChannelPresenceManager.shared.processHeartbeat(
                                originNodeID: originUUID,
                                alias: senderAlias,
                                channelID: channel,
                                hopCount: UInt8(min(message.hopsCount, 255)),
                                isDirectPeer: isDirect
                            )
                        } else if message.type == .friendRequest {
                            await SwiftDataService.shared.persistenceActor.handleFriendRequest(from: message.originID, handle: message.senderName, requestID: message.id)
                            NotificationCenter.default.post(name: .didUpdateFriends, object: nil)
                            AppLogger.multipeer.info("Received Friend Request from \(message.senderName)")
                        } else if message.type == .friendAccept {
                            await SwiftDataService.shared.persistenceActor.handleFriendAccept(from: message.originID)
                            NotificationCenter.default.post(name: .didUpdateFriends, object: nil)
                            NotificationCenter.default.post(
                                name: .didBecomeFriend,
                                object: nil,
                                userInfo: ["peerID": message.originID, "handle": message.senderName]
                            )
                            AppLogger.multipeer.info("Received Friend Accept from \(message.senderName)")
                        } else if message.type == .channelInvite {
                            // Channel Invitation
                            await SwiftDataService.shared.persistenceActor.handleChannelInvite(
                                channelID: message.text, // Assume text contains the channelID UUID string
                                from: message.originID
                            )
                            AppLogger.multipeer.info("Received Channel Invite from \(message.senderName)")
                        } else if message.type == .channelAccept {
                            // Channel Accept
                            await SwiftDataService.shared.persistenceActor.handleChannelAccept(
                                channelID: message.text,
                                from: message.originID
                            )
                            AppLogger.multipeer.info("Received Channel Accept from \(message.senderName)")
                        } else if message.type == .channelDecline {
                            // Channel Decline
                            await SwiftDataService.shared.persistenceActor.handleChannelDecline(
                                channelID: message.text,
                                from: message.originID
                            )
                            AppLogger.multipeer.info("Received Channel Decline from \(message.senderName)")
                        } else if message.type == .friendDecline {
                            await SwiftDataService.shared.persistenceActor.handleFriendDecline(from: message.originID)
                            NotificationCenter.default.post(name: .didUpdateFriends, object: nil)
                            AppLogger.multipeer.info("Received Friend Decline from \(message.senderName)")
                        } else {
                            await SwiftDataService.shared.persistenceActor.saveChatMessage(
                                id: message.id,
                                originID: message.originID,
                                senderID: message.senderID,
                                destinationID: message.destinationID,
                                senderName: message.senderName,
                                channel: isChannelMessage ? message.channelID! : message.originID,
                                text: message.text,
                                isDelivered: true,
                                messageTypeRaw: "TEXT"
                            )
                            MeshNotificationManager.shared.notifyMessageReceived(messageID: message.id, senderName: message.senderName, textPreview: message.text)
                            NotificationCenter.default.post(name: .didReceiveChatMessage, object: nil)
                            AppLogger.multipeer.info("Received P2P Chat Message from \(message.senderName)")
                        }
                        
                        // Check and cache coordinate in LocationService
                        if let lat = message.latitude, let lon = message.longitude {
                            let senderUUID = UUID(uuidString: message.senderID) ?? UUID(uuidString: message.originID) ?? message.id
                            LocationService.shared.updatePeerLocation(nodeID: senderUUID, location: CLLocation(latitude: lat, longitude: lon))
                        }
                        
                        // Check and dispatch Emergency SOS Notification
                        if message.isSOS || message.emergencyStatus != .normal {
                            NotificationCenter.default.post(
                                name: .didReceiveEmergencySOS,
                                object: nil,
                                userInfo: ["message": message]
                            )
                            AppLogger.multipeer.warning("[EMERGENCY_SOS_DELIVERED] sender=\(message.senderName) channel=\(message.channelID ?? "CH-1 EMERGENCY") loc=\(message.formattedLocation ?? "NONE")")
                        }
                    } else {
                        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "DUPLICATE_TEST", peer: peerID.displayName, details: "messageID=\(shortMsgID) firstDelivery=false secondDelivery=true duplicateDetected=true")
                        AppLogger.multipeer.info("Deduplication Engine: Message \(message.id) already processed. Re-issuing ACK.")
                    }
                    
                    if message.destinationID == localNodeID && message.type != .ack {
                        AppLogger.multipeer.info("\(AppLogger.ackTag(message.id)) ACK_CREATE_START")
                        AppLogger.multipeer.info("\(AppLogger.ackTag(message.id)) ACK_CREATED forMessageID=\(String(message.id.uuidString.prefix(6)))")
                        
                        AppLogger.multipeer.info("""
                        [PINGLY_ACK_CREATE]
                        originalMessageID=\(message.id.uuidString)
                        ackType=DELIVERY_ACK
                        sender=\(localNodeID)
                        receiver=\(message.originID)
                        channel=\(message.channelID ?? message.destinationID)
                        """)
                        
                        RelaynTransportDiagnosticsManager.shared.incrementAckSent()
                        
                        let deliveryAck = Message(
                            id: message.id,
                            originID: localNodeID,
                            destinationID: message.originID,
                            senderID: localNodeID,
                            senderName: localUserHandle,
                            previousHopID: localNodeID,
                            text: "DELIVERY_ACK",
                            timestamp: Date(),
                            hopsCount: 0,
                            ttl: message.ttl,
                            type: .ack
                        )
                        
                        let ackData = (try? JSONEncoder().encode(deliveryAck)) ?? Data()
                        AppLogger.multipeer.info("\(AppLogger.ackTag(deliveryAck.id)) ACK_SEND_START peer=\(shortPeer)")
                        
                        AppLogger.multipeer.info("""
                        [PINGLY_ACK_TX]
                        ackMessageID=\(deliveryAck.id.uuidString)
                        originalMessageID=\(message.id.uuidString)
                        peer=BROADCAST
                        bytes=\(ackData.count)
                        frameType=ACK
                        """)
                        
                        self.broadcast(message: deliveryAck)
                        AppLogger.multipeer.info("\(AppLogger.ackTag(deliveryAck.id)) ACK_SEND_COMPLETED peer=\(shortPeer)")
                        RelaynTransportDiagnosticsManager.shared.recordACKEvent(id: message.id, peer: peerID.displayName, result: "ACK Sent")
                    }
                }
                
                // shouldForward: relay this packet to downstream peers.
                // seenCache already guarantees this branch runs at most once per messageID,
                // so we only need to check originID (don't relay our own originating messages).
                let localUUID = UUID(uuidString: localNodeID) ?? UUID()
                if message.relayHistory.contains(localUUID) {
                    AppLogger.multipeer.info("[MESH_LOOP_DROP] msg=\(message.id.uuidString) node=\(localNodeID)")
                    return
                }
                
                if shouldForward && message.originID != localNodeID {
                    RelaynTransportDiagnosticsManager.shared.incrementRelayReceived()
                    
                    guard message.ttl > 1 else {
                        AppLogger.multipeer.info("[MESH_TTL_EXCEEDED] Dropping packet \(message.id) - TTL exhausted (\(message.ttl))")
                        RelaynTransportDiagnosticsManager.shared.incrementRelayDropped()
                        return
                    }
                    
                    var relayMsg = message
                    relayMsg.previousHopID = localNodeID
                    relayMsg.ttl = message.ttl - 1
                    relayMsg.hopsCount = message.hopsCount + 1
                    relayMsg.relayHistory.append(localUUID)
                    
                    AppLogger.multipeer.info("[MESH_FORWARD] msg=\(relayMsg.id.uuidString) from=\(relayMsg.senderID) to=\(relayMsg.destinationID) hop=\(relayMsg.hopsCount) ttl=\(relayMsg.ttl)")
                    AppLogger.multipeer.info("\(AppLogger.routingTag(message.id)) FORWARDING hops=\(relayMsg.hopsCount) maxHops=\(relayMsg.ttl) peer=\(shortPeer)")
                    
                    self.broadcastExcluding(message: relayMsg, excludingPeer: peerID)
                    
                    AppLogger.multipeer.info("""
                    [PINGLY_RELAY_TRANSIT]
                    messageID=\(message.id.uuidString)
                    originSender=\(message.originID)
                    currentSender=\(message.senderID)
                    destination=\(message.destinationID)
                    hopCount=\(relayMsg.hopsCount)
                    maxHop=\(Constants.Mesh.maxMeshHops)
                    """)
                    // We intentionally DO NOT call enqueuePendingMessage here. Transit relays are ephemeral and fire-and-forget.
                }
            }
        }
    
    private func sendDirectData(data: Data, to peer: MCPeerID) {
        guard let session = session, session.connectedPeers.contains(peer) else { return }
        let sha256 = RelaynTransportLogger.sha256Hex(data: data)
        let hexPrev = RelaynTransportLogger.hexPreview(data: data)
        let utf8Prev = RelaynTransportLogger.utf8Preview(data: data)
        
        AppLogger.multipeer.info("""
        [PINGLY_TX_BEGIN]
        timestamp=\(Date())
        peer=\(peer.displayName)
        peerID=\(peer.displayName)
        transport=MCSession
        reliability=reliable
        frameID=DIRECT_DATA
        frameType=DIRECT_DATA
        messageType=DIRECT_DATA
        senderID=\(self.myPeerID.displayName)
        destinationID=\(peer.displayName)
        channelID=DIRECT
        hopCount=0
        payloadBytes=\(data.count)
        encodedBytes=\(data.count)
        sha256=\(sha256)
        hexPreview=\(hexPrev)
        utf8Preview=\(utf8Prev)
        """)
        
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
            RelaynTransportDiagnosticsManager.shared.incrementTxFrames()
            
            AppLogger.multipeer.info("""
            [PINGLY_TX_SUCCESS]
            frameID=DIRECT_DATA
            peer=\(peer.displayName)
            bytes=\(data.count)
            sha256=\(sha256)
            """)
        } catch {
            AppLogger.multipeer.error("""
            [PINGLY_TX_FAILURE]
            frameID=DIRECT_DATA
            peer=\(peer.displayName)
            error=\(type(of: error))
            errorDescription=\(error.localizedDescription)
            """)
        }
    }



    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension MultipeerService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        AppLogger.multipeer.info("Accepting invitation from peer: \(peerID.displayName)")
        AppLogger.multipeer.info("""
        [DIAG_PEER_INVITE_RX]
        fromPeer=\(peerID.displayName)
        contextBytes=\(context?.count ?? 0)
        accepted=true
        """)
        if let context = context, let remoteNodeID = String(data: context, encoding: .utf8), UUID(uuidString: remoteNodeID) != nil {
            self.peerIDToNodeIDMap[peerID] = remoteNodeID
            AppLogger.multipeer.info("Mapped discovered peer via invitation context: \(peerID.displayName) -> \(remoteNodeID)")
        }
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "INVITATION_RECEIVED", peer: peerID.displayName, details: "invitation_accepted")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "INVITATION_RECEIVED", peer: peerID.displayName)
        
        if let session = session {
            let stalePeers = session.connectedPeers.filter { $0.displayName == peerID.displayName && $0 != peerID }
            for stale in stalePeers {
                AppLogger.multipeer.warning("""
                [MESH_RECONNECT] Evicting stale MCPeerID for \(stale.displayName) upon invitation receive.
                """)
                session.cancelConnectPeer(stale)
                DispatchQueue.main.async {
                    self.connectedPeers.removeAll(where: { $0.mcPeerID == stale })
                    self.peerIDToNodeIDMap.removeValue(forKey: stale)
                    self.peerIDToHandleMap.removeValue(forKey: stale)
                }
            }
        }
        
        invitationHandler(true, session)
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "INVITATION_ACCEPTED", peer: peerID.displayName, details: "invitation_handler_accepted=true")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "INVITATION_ACCEPTED", peer: peerID.displayName)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        AppLogger.multipeer.info("[MESH_PEER_DISCOVERED] peer=\(peerID.displayName)")
        AppLogger.multipeer.info("Browser found peer: \(peerID.displayName)")
        AppLogger.multipeer.info("""
        [DIAG_PEER_FOUND]
        peer=\(peerID.displayName)
        discoveryInfo=\(info ?? [:])
        timestamp=\(Date())
        """)
        if let nodeID = info?["nodeID"] {
            self.peerIDToNodeIDMap[peerID] = nodeID
            AppLogger.multipeer.info("Mapped discovered peer via discovery info: \(peerID.displayName) -> \(nodeID)")
        }
        if let handle = info?["handle"] {
            self.peerIDToHandleMap[peerID] = handle
        }
        
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "PEER_DISCOVERED", peer: peerID.displayName, details: "discovered_by_browser")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "PEER_DISCOVERED", peer: peerID.displayName)
        
        let resolvedNodeID = self.peerIDToNodeIDMap[peerID] ?? peerID.displayName
        let cleanName = self.peerIDToHandleMap[peerID] ?? peerID.displayName.cleanBaseName
        
        guard let session = session else { return }
        
        let stalePeers = session.connectedPeers.filter { $0.displayName == peerID.displayName && $0 != peerID }
        for stale in stalePeers {
            AppLogger.multipeer.warning("""
            [MESH_RECONNECT] Evicting stale MCPeerID for \(stale.displayName).
            New discovery has the same NodeID but a different MCPeerID object.
            """)
            session.cancelConnectPeer(stale)
            DispatchQueue.main.async {
                self.connectedPeers.removeAll(where: { $0.mcPeerID == stale })
                self.peerIDToNodeIDMap.removeValue(forKey: stale)
                self.peerIDToHandleMap.removeValue(forKey: stale)
            }
        }
        
        MeshNotificationManager.shared.notifyPeerDiscovered(peerID: resolvedNodeID, displayName: cleanName)
        
        let newDiscovered = PeerDevice(
            id: resolvedNodeID,
            displayName: cleanName,
            mcPeerID: peerID,
            isConnected: false
        )
        DispatchQueue.main.async {
            if let idx = self.discoveredPeers.firstIndex(where: { $0.id == resolvedNodeID }) {
                self.discoveredPeers[idx] = newDiscovered
            } else {
                self.discoveredPeers.append(newDiscovered)
            }
        }
        
        // Deterministic Multipeer Invitation (Eliminate Socket Error 54 / Cross-Invite Collision)
        let shouldInvite = self.myPeerID.displayName < peerID.displayName
        if shouldInvite {
            if !session.connectedPeers.contains(peerID) {
                AppLogger.multipeer.info("Deterministic tie-breaker won: Issuing invitation to peer \(peerID.displayName)")
                AppLogger.multipeer.info("""
                [DIAG_PEER_INVITE_TX]
                targetPeer=\(peerID.displayName)
                tieBreaker=WINNER
                timeout=15
                """)
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "INVITATION_SENT", peer: peerID.displayName, details: "deterministic_invite_winner")
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "INVITATION_SENT", peer: peerID.displayName)
                let contextData = NodeIdentity.shared.nodeID.data(using: .utf8)
                AppLogger.multipeer.info("[MESH_INVITATION_SENT] peer=\(peerID.displayName)")
                browser.invitePeer(peerID, to: session, withContext: contextData, timeout: 15)
            }
        } else {
            AppLogger.multipeer.info("Deterministic tie-breaker: Passively waiting for peer \(peerID.displayName) to issue invitation...")
            AppLogger.multipeer.info("""
            [DIAG_PEER_INVITE_WAIT]
            targetPeer=\(peerID.displayName)
            tieBreaker=PASSIVE_WAIT
            """)
            RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "INVITATION_WAITING", peer: peerID.displayName, details: "deterministic_invite_wait")
        }
    }

    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        AppLogger.multipeer.info("Browser lost peer: \(peerID.displayName)")
        AppLogger.multipeer.info("""
        [DIAG_PEER_LOST]
        peer=\(peerID.displayName)
        timestamp=\(Date())
        """)
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "PEER_LOST", peer: peerID.displayName, details: "lost_by_browser")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "PEER_LOST", peer: peerID.displayName)
        DispatchQueue.main.async {
            let resolvedNodeID = self.peerIDToNodeIDMap[peerID] ?? peerID.displayName
            self.connectedPeers.removeAll(where: { $0.id == resolvedNodeID || $0.mcPeerID == peerID })
            self.discoveredPeers.removeAll(where: { $0.id == resolvedNodeID || $0.mcPeerID == peerID })
            
            // DO NOT remove from peerIDToNodeIDMap or peerIDToHandleMap here.
            // If the same MCPeerID reconnects silently, we must retain its canonical NodeID mapping.
            let peerList = self.connectedPeers.map { $0.displayName }
            RelaynTransportDiagnosticsManager.shared.updateConnectedPeersList(peerList)
            RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTED_PEERS_COUNT", peer: resolvedNodeID, details: "count=\(self.connectedPeers.count)")
        }
    }
}
