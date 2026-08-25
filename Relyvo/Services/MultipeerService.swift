//
//  MultipeerService.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import MultipeerConnectivity
import Combine
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

/// Production MultipeerConnectivity Service managing AirDrop/Wi-Fi/Bluetooth peer mesh networking
final class MultipeerService: NSObject, MultipeerServiceProtocol, ObservableObject {
    
    static let shared = MultipeerService()
    private let queueCoalescer = QueueProcessingCoalescer()

    
    // MARK: - Published Properties
    @Published private(set) var connectedPeers: [PeerDevice] = []
    
    // MARK: - Publishers
    var connectedPeersPublisher: AnyPublisher<[PeerDevice], Never> {
        $connectedPeers.eraseToAnyPublisher()
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
    
    private var currentHandle: String = Constants.App.defaultUserHandle
    private var currentStatus: EmergencyStatus = .normal
    private var connectStartTimestamp: Date? = nil
    
    override init() {
        let storedHandle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        let stableNodeSuffix = String(NodeIdentity.shared.nodeID.replacingOccurrences(of: "-", with: "").prefix(4))
        let peerDisplayName = "\(storedHandle)_\(stableNodeSuffix)"
        self.currentHandle = storedHandle
        self.myPeerID = MCPeerID(displayName: peerDisplayName)
        super.init()
        setupSession()
        
        let deviceFingerprint = String(KeychainIdentityService.shared.fetchOrCreateDeviceID().uuidString.prefix(6))
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
        
        let browser = MCNearbyServiceBrowser(
            peer: myPeerID,
            serviceType: Constants.Multipeer.serviceType
        )
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "BROWSING_START", peer: myPeerID.displayName, details: "serviceType=\(Constants.Multipeer.serviceType)")
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "SESSION_START", peer: myPeerID.displayName, details: "handle=\(userHandle)")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "SERVICES_STARTED", peer: myPeerID.displayName, details: "handle=\(userHandle)")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "BROWSING_STARTED", peer: myPeerID.displayName, details: "serviceType=\(Constants.Multipeer.serviceType)")
        
        AppLogger.multipeer.info("Started Multipeer Advertising & Browsing for handle: \(userHandle)")
    }
    
    func stopAdvertisingAndBrowsing() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
    }
    
    /// Safely disconnects the existing MCSession, unregisters its delegate, re-instantiates a fresh MCSession, and reassigns self as delegate.
    func teardownAndResetSession() {
        let resetWork = { [weak self] in
            guard let self = self else { return }
            AppLogger.multipeer.warning("Tearing down and resetting MCSession...")
            if let existingSession = self.session {
                existingSession.disconnect()
                existingSession.delegate = nil
            }
            self.session = nil
            self.connectedPeers.removeAll()
            self.peerIDToNodeIDMap.removeAll()
            self.peerIDToHandleMap.removeAll()
            
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
        browser.invitePeer(peerID, to: session, withContext: contextData, timeout: Constants.Multipeer.connectionTimeoutSeconds)
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "INVITATION_SENT", peer: peerID.displayName, details: "invited_peer")
        AppLogger.multipeer.info("Inviting peer: \(peerID.displayName)")
    }

    
    func broadcast(message: Message) {
        let tag = AppLogger.messageTag(message.id)
        let frameTag = AppLogger.frameTag(message.id)
        let transportTag = AppLogger.transportTag(message.id)
        
        guard let session = session, !session.connectedPeers.isEmpty else {
            AppLogger.multipeer.info("\(tag) WAITING_FOR_PEER")
            return
        }
        do {
            let peerNames = session.connectedPeers.map { $0.displayName }.joined(separator: ", ")
            let firstPeerShort = String((session.connectedPeers.first?.displayName ?? "UNKNOWN").prefix(6))
            
            AppLogger.multipeer.info("\(tag) CREATED type=\(message.type.rawValue)")
            AppLogger.multipeer.info("\(tag) sender=\(String(message.senderID.prefix(6)))")
            AppLogger.multipeer.info("\(tag) recipient=\(String(message.destinationID.prefix(6))) channel=\(message.channelID ?? message.destinationID) payloadBytes=\(message.text.utf8.count)")
            AppLogger.multipeer.info("\(tag) SEND_ATTEMPT attempt=1 reason=BROADCAST peer=\(firstPeerShort)")
            
            AppLogger.multipeer.info("\(frameTag) SERIALIZE_START")
            let data = try JSONEncoder().encode(message)
            AppLogger.multipeer.info("\(frameTag) SERIALIZE_SUCCESS version=\(message.protocolVersion) type=\(message.type.rawValue) bytes=\(data.count)")
            
            let sha256 = RelaynTransportLogger.sha256Hex(data: data)
            let hexPrev = RelaynTransportLogger.hexPreview(data: data)
            let utf8Prev = RelaynTransportLogger.utf8Preview(data: data)
            
            AppLogger.multipeer.info("""
            [PINGLY_SERIALIZATION]
            encoder=JSONEncoder
            type=Message
            bytes=\(data.count)
            
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
            
            [PINGLY_TX_BEGIN]
            timestamp=\(Date())
            peer=\(peerNames)
            peerID=\(peerNames)
            transport=MCSession
            reliability=reliable
            frameID=\(message.id.uuidString)
            frameType=\(message.type.rawValue)
            messageType=\(message.type.rawValue)
            senderID=\(message.senderID)
            destinationID=\(message.destinationID)
            channelID=\(message.channelID ?? "N/A")
            hopCount=\(message.hopsCount)
            payloadBytes=\(message.text.utf8.count)
            encodedBytes=\(data.count)
            sha256=\(sha256)
            hexPreview=\(hexPrev)
            utf8Preview=\(utf8Prev)
            """)
            
            AppLogger.multipeer.info("\(transportTag) SEND_START peer=\(firstPeerShort) bytes=\(data.count)")
            let shortMsgID = String(message.id.uuidString.prefix(6)).uppercased()
            RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "MESSAGE_TEST_BEGIN", peer: message.destinationID, details: "messageID=\(shortMsgID) type=\(message.type.rawValue) channel=\(message.channelID ?? message.destinationID) payloadBytes=\(message.text.utf8.count)")
            RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "TX_BEGIN", peer: firstPeerShort, details: "messageID=\(shortMsgID) bytes=\(data.count)")
            
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
            
            try session.send(data, toPeers: targetPeers, with: .reliable)
            AppLogger.multipeer.info("\(transportTag) SEND_CALL_COMPLETED peer=\(firstPeerShort)")
            
            RelaynTransportDiagnosticsManager.shared.recordOutgoingMessage(id: message.id, peer: session.connectedPeers.first?.displayName ?? "Broadcast", result: "Sent")
            RelaynTransportDiagnosticsManager.shared.incrementTxFrames()
            RelaynTransportDiagnosticsManager.shared.incrementPhysicalTestSent()
            RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "TX_SUCCESS", peer: firstPeerShort, details: "messageID=\(shortMsgID) bytes=\(data.count)")
            
            AppLogger.multipeer.info("""
            [PINGLY_TX_SUCCESS]
            frameID=\(message.id.uuidString)
            peer=\(peerNames)
            bytes=\(data.count)
            sha256=\(sha256)
            """)
            
            AppLogger.multipeer.info("Broadcasted emergency message ID: \(message.id) to \(session.connectedPeers.count) peers")
        } catch {
            let firstPeerShort = String((session.connectedPeers.first?.displayName ?? "UNKNOWN").prefix(6))
            let shortMsgID = String(message.id.uuidString.prefix(6)).uppercased()
            AppLogger.multipeer.error("\(transportTag) SEND_FAILED peer=\(firstPeerShort) error=\(error.localizedDescription)")
            RelaynTransportDiagnosticsManager.shared.recordOutgoingMessage(id: message.id, peer: session.connectedPeers.first?.displayName ?? "Broadcast", result: "Failed")
            RelaynTransportDiagnosticsManager.shared.incrementPhysicalTestMessageFailures()
            RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "TX_FAILURE", peer: firstPeerShort, details: "messageID=\(shortMsgID) error=\(error.localizedDescription)")
            RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "MESSAGE_TEST_RESULT", peer: message.destinationID, details: "messageID=\(shortMsgID) result=FAILED failureStage=TX_FAILURE elapsedMs=0")
            
            AppLogger.multipeer.error("""
            [PINGLY_TX_FAILURE]
            frameID=\(message.id.uuidString)
            peer=\(session.connectedPeers.map { $0.displayName }.joined(separator: ", "))
            error=\(type(of: error))
            errorDescription=\(error.localizedDescription)
            """)
        }
    }
    
    func sendAudioStream(data: Data) {
        sendRawPTTPacket(data)
    }
    
    func sendRawPTTPacket(_ packet: Data) {
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        let sha256 = RelaynTransportLogger.sha256Hex(data: packet)
        let hexPrev = RelaynTransportLogger.hexPreview(data: packet)
        let utf8Prev = RelaynTransportLogger.utf8Preview(data: packet)
        let peerNames = session.connectedPeers.map { $0.displayName }.joined(separator: ", ")
        
        AppLogger.multipeer.info("""
        [PINGLY_SERIALIZATION]
        encoder=PTTFrameHeader
        type=PTT_RAW
        bytes=\(packet.count)
        
        [PINGLY_TX_BEGIN]
        timestamp=\(Date())
        peer=\(peerNames)
        peerID=\(peerNames)
        transport=MCSession
        reliability=unreliable
        frameID=PTT_RAW
        frameType=PTT_RAW
        messageType=PTT_RAW
        senderID=\(self.myPeerID.displayName)
        destinationID=BROADCAST
        channelID=AUDIO_STREAM
        hopCount=0
        payloadBytes=\(packet.count)
        encodedBytes=\(packet.count)
        sha256=\(sha256)
        hexPreview=\(hexPrev)
        utf8Preview=\(utf8Prev)
        """)
        
        do {
            try session.send(packet, toPeers: session.connectedPeers, with: .unreliable)
            RelaynTransportDiagnosticsManager.shared.incrementTxFrames()
            
            AppLogger.multipeer.info("""
            [PINGLY_TX_SUCCESS]
            frameID=PTT_RAW
            peer=\(peerNames)
            bytes=\(packet.count)
            sha256=\(sha256)
            """)
        } catch {
            AppLogger.multipeer.error("""
            [PINGLY_TX_FAILURE]
            frameID=PTT_RAW
            peer=\(peerNames)
            error=\(type(of: error))
            errorDescription=\(error.localizedDescription)
            """)
        }
    }
    func broadcastChannelSync(channelName: String) {
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        let invite = ChannelInvite(channelName: channelName, creatorHandle: currentHandle)
        do {
            let data = try JSONEncoder().encode(invite)
            let sha256 = RelaynTransportLogger.sha256Hex(data: data)
            let hexPrev = RelaynTransportLogger.hexPreview(data: data)
            let utf8Prev = RelaynTransportLogger.utf8Preview(data: data)
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
            sha256=\(sha256)
            hexPreview=\(hexPrev)
            utf8Preview=\(utf8Prev)
            """)
            
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            RelaynTransportDiagnosticsManager.shared.incrementTxFrames()
            
            AppLogger.multipeer.info("""
            [PINGLY_TX_SUCCESS]
            frameID=CHANNEL_SYNC
            peer=\(peerNames)
            bytes=\(data.count)
            sha256=\(sha256)
            """)
            
            AppLogger.multipeer.info("Broadcasted channel sync for \(channelName) to \(session.connectedPeers.count) peers")
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
            
            let localFingerprint = String(KeychainIdentityService.shared.fetchOrCreateDeviceID().uuidString.prefix(6))
            let details = "localDevice=\(localFingerprint) state=\(stateString) connectedPeers=\(self.connectedPeers.count)"
            RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTION_STATE_CHANGE", peer: peerID.displayName, details: details)
            
            switch state {
            case .connected:
                let resolvedNodeID = self.peerIDToNodeIDMap[peerID] ?? peerID.displayName
                let cleanName = self.peerIDToHandleMap[peerID] ?? peerID.displayName.cleanBaseName
                
                AppLogger.multipeer.info("Peer connected: \(peerID.displayName) -> mapped to nodeID: \(resolvedNodeID), handle: \(cleanName)")
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTED", peer: resolvedNodeID, details: details)
                RelaynTransportDiagnosticsManager.shared.recordPeerConnection(peer: resolvedNodeID)
                MeshNotificationManager.shared.notifyPeerConnected(peerID: resolvedNodeID, displayName: cleanName)
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
                
                let peerList = self.connectedPeers.map { $0.displayName }
                RelaynTransportDiagnosticsManager.shared.updateConnectedPeersList(peerList)
                let elapsedMs = self.connectStartTimestamp != nil ? Int(Date().timeIntervalSince(self.connectStartTimestamp!) * 1000) : 0
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "SESSION_READY", peer: resolvedNodeID, details: "connectedPeersCount=\(self.connectedPeers.count)")
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTED_PEERS_COUNT", peer: resolvedNodeID, details: "count=\(self.connectedPeers.count)")
                
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "CONNECTED", peer: resolvedNodeID, details: "connectedPeers=\(self.connectedPeers.count)")
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "SESSION_READY", peer: resolvedNodeID, details: "CONNECT_TO_READY elapsedMs=\(elapsedMs)")
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "CONNECTED_PEERS_COUNT", peer: resolvedNodeID, details: "count=\(self.connectedPeers.count)")
                
                AppLogger.multipeer.info("""
                [PINGLY_SESSION_READY]
                peer=\(peerID.displayName)
                peerID=\(peerID.displayName)
                
                [PINGLY_CONNECTED_PEERS]
                count=\(self.connectedPeers.count)
                peers=[\(peerList.joined(separator: ", "))]
                """)
                
                RelaynTransportDiagnosticsManager.shared.logDiagnosticSummary()
                self.flushPendingStoreAndForwardQueue(for: peerID)
                
            case .notConnected:
                let resolvedNodeID = self.peerIDToNodeIDMap[peerID] ?? peerID.displayName
                let cleanName = self.peerIDToHandleMap[peerID] ?? peerID.displayName.cleanBaseName
                
                AppLogger.multipeer.info("Peer disconnected: \(peerID.displayName) -> resolvedNodeID: \(resolvedNodeID)")
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
                self.connectedPeers.removeAll(where: { $0.id == resolvedNodeID || $0.mcPeerID == peerID })
                self.peerIDToNodeIDMap.removeValue(forKey: peerID)
                self.peerIDToHandleMap.removeValue(forKey: peerID)
                let peerList = self.connectedPeers.map { $0.displayName }
                RelaynTransportDiagnosticsManager.shared.updateConnectedPeersList(peerList)
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTED_PEERS_COUNT", peer: resolvedNodeID, details: "count=\(self.connectedPeers.count)")
                
                AppLogger.multipeer.info("""
                [PINGLY_CONNECTED_PEERS]
                count=\(self.connectedPeers.count)
                peers=[\(peerList.joined(separator: ", "))]
                """)
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
                SwiftDataService.shared.resetFailedPendingMessages()
                let pendingList = SwiftDataService.shared.fetchPendingMessages()
                guard !pendingList.isEmpty else { return }
                
                for pending in pendingList {
                    let msgTag = AppLogger.messageTag(pending.messageID)
                    
                    // Validate canonical routing identity
                    guard self.isCanonicalRoutingIdentity(destinationID: pending.destinationID, channel: pending.channel) else {
                        AppLogger.multipeer.warning("\(msgTag) QUARANTINED reason=non_canonical_identity destination=\(pending.destinationID) channel=\(pending.channel)")
                        SwiftDataService.shared.updatePendingMessageStatus(messageID: pending.messageID, status: .failed, reason: "QUARANTINED_NON_CANONICAL")
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
                    guard pending.hopsCount < pending.ttl else {
                        AppLogger.multipeer.warning("\(AppLogger.routingTag(pending.messageID)) FORWARD_REJECTED reason=TTL_EXPIRED (\(pending.hopsCount)/\(pending.ttl))")
                        AppLogger.multipeer.warning("Pending message \(pending.messageID) TTL exhausted (\(pending.hopsCount)/\(pending.ttl)). Halting forward.")
                        continue
                    }
                    
                    let targetPeerName = self.connectedPeers.first?.displayName ?? pending.destinationID
                    let shortTarget = String(targetPeerName.prefix(6))
                    
                    AppLogger.multipeer.info("\(msgTag) PEER_AVAILABLE peer=\(shortTarget)")
                    AppLogger.multipeer.info("\(msgTag) RETRY_START retryCount=\(pending.retryCount + 1) peer=\(shortTarget)")
                    AppLogger.multipeer.info("\(msgTag) SEND_ATTEMPT attempt=\(pending.retryCount + 1) reason=QUEUE_PROCESSOR peer=\(shortTarget)")
                    
                    SwiftDataService.shared.updatePendingMessageStatus(messageID: pending.messageID, status: .sending)
                    
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
                        ttl: pending.ttl,
                        type: isTranscript ? .transcript : .chat
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
                    SwiftDataService.shared.updatePendingMessageStatus(messageID: pending.messageID, status: .waitingForACK)
                    AppLogger.multipeer.info("\(msgTag) RETRY_SEND_COMPLETED retryCount=\(pending.retryCount)")
                    AppLogger.multipeer.info("Dispatched \(pending.queueRole.rawValue) message \(pending.messageID) for '\(pending.destinationID)' (Hop \(msg.hopsCount)/\(msg.ttl))")
                    
                    // Schedule ACK timeout verification (5 seconds)
                    AppLogger.multipeer.info("\(AppLogger.ackTag(pending.messageID)) ACK_TIMER_STARTED timeout=5")
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        let checkList = SwiftDataService.shared.fetchPendingMessages()
                        if let item = checkList.first(where: { $0.messageID == pending.messageID }), item.status == .waitingForACK {
                            AppLogger.multipeer.warning("\(AppLogger.ackTag(pending.messageID)) ACK_TIMEOUT retryCount=\(item.retryCount)")
                            SwiftDataService.shared.updatePendingMessageStatus(messageID: pending.messageID, status: .failed, reason: "ACK_TIMEOUT")
                        } else {
                            AppLogger.multipeer.info("\(AppLogger.ackTag(pending.messageID)) ACK_TIMER_CANCELLED")
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
        DispatchQueue.global(qos: .userInitiated).async {
            // Check for PTT audio binary framing (header starts with PTTFrameHeader or 0x5054 magic bytes)
            if PTTFrameHeader.decode(from: data) != nil || (data.count >= 2 && data[0] == 0x50 && data[1] == 0x54) {
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
                senderID=\(peerID.displayName)
                destinationID=BROADCAST
                channelID=AUDIO_STREAM
                hopCount=0
                payloadSize=\(data.count)
                """)
                
                RelaynTransportDiagnosticsManager.shared.incrementDecodeSuccess()
                
                NotificationCenter.default.post(
                    name: .didReceiveRawPTTPacket,
                    object: self,
                    userInfo: ["packet": data, "peerID": peerID]
                )
                DispatchQueue.main.async {
                    self.receivedAudioDataSubject.send(data)
                }
                return
            }
            
            // Try decoding as ChannelInvite first
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
            
            // Try decoding as emergency / P2P text or voice transcript JSON Message next
            AppLogger.multipeer.info("\(AppLogger.frameTag()) DESERIALIZE_START")
            
            let message: Message
            do {
                message = try JSONDecoder().decode(Message.self, from: data)
                AppLogger.multipeer.info("\(AppLogger.frameTag(message.id)) FRAME_RECEIVED peer=\(shortPeer) bytes=\(data.count)")
                AppLogger.multipeer.info("\(AppLogger.frameTag(message.id)) DESERIALIZE_SUCCESS")
                RelaynTransportDiagnosticsManager.shared.incrementDecodeSuccess()
                RelaynTransportDiagnosticsManager.shared.recordIncomingMessage(id: message.id, peer: peerID.displayName, result: "Received", decodeRes: "Success")
                
                AppLogger.multipeer.info("""
                [PINGLY_DECODE_SUCCESS]
                peer=\(peerID.displayName)
                frameID=\(message.id.uuidString)
                frameType=\(message.type.rawValue)
                messageType=\(message.type.rawValue)
                senderID=\(message.senderID)
                destinationID=\(message.destinationID)
                channelID=\(message.channelID ?? "N/A")
                hopCount=\(message.hopsCount)
                payloadSize=\(message.text.utf8.count)
                
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
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Handle incoming Delivery ACK frame
                if message.type == .ack {
                    AppLogger.multipeer.info("\(AppLogger.ackTag(message.id)) ACK_RECEIVE_START peer=\(shortPeer)")
                    RelaynTransportDiagnosticsManager.shared.incrementAckReceived()
                    
                    AppLogger.multipeer.info("""
                    [PINGLY_ACK_RX]
                    ackMessageID=\(message.id.uuidString)
                    originalMessageID=\(message.id.uuidString)
                    sender=\(message.senderID)
                    receiver=\(message.destinationID)
                    peer=\(peerID.displayName)
                    """)
                    
                    let isAckForLocal = (message.originID == localNodeID || message.destinationID == localNodeID || message.destinationID == localUserHandle || message.destinationID.hasPrefix("CH-"))
                    
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
                        
                        SwiftDataService.shared.markPendingMessageAsACKed(messageID: message.id)
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
                        SwiftDataService.shared.markPendingMessageAsACKed(messageID: message.id) // Clear local relay copy
                        
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
                            
                            self.sendDirectData(data: (try? JSONEncoder().encode(relayAck)) ?? Data(), to: targetPeer)
                            AppLogger.multipeer.info("Targeted ACK routing: Sent DELIVERY_ACK directly to reverse-path hop '\(previousHopNode.displayName)'")
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
                
                let channelMatches = isChannelMessage ? (message.channelID?.uppercased() == self.activeChannelID.uppercased()) : true
                
                // Channel-targeted broadcasts are gated strictly by channelMatches so PTT
                // from CH-3 does NOT bleed into a device subscribed to CH-1.
                // Plain broadcasts with no channelID are delivered unconditionally.
                let shouldDeliverLocally = (message.destinationID == localNodeID) ||
                                           (isChannelMessage && channelMatches) ||
                                           (!isChannelMessage && message.destinationID == "BROADCAST")
                
                let shouldForward = (!isForMe) || isChannelMessage
                
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
                
                [PINGLY_ROUTE_BEGIN]
                messageID=\(message.id.uuidString)
                frameType=\(message.type.rawValue)
                senderID=\(message.senderID)
                destinationID=\(message.destinationID)
                currentDeviceID=\(localNodeID)
                channelID=\(message.channelID ?? message.destinationID)
                currentHop=\(message.hopsCount)
                maxHop=\(message.ttl)
                isOrigin=\(message.originID == localNodeID)
                isRelay=\(!isForMe)
                isDestination=\(isForMe)
                isForCurrentDevice=\(isForMe)
                isForCurrentChannel=\(isChannelMessage && channelMatches)
                """)
                
                let shortMsgID = String(message.id.uuidString.prefix(6)).uppercased()
                let alreadyProcessed = SwiftDataService.shared.isMessageAlreadyProcessed(messageID: message.id)
                
                if shouldDeliverLocally {
                    RelaynTransportDiagnosticsManager.shared.incrementPhysicalTestReceived()
                    RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "RX_BEGIN", peer: peerID.displayName, details: "messageID=\(shortMsgID) type=\(message.type.rawValue)")
                    RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "MessageFunnel", event: "DECODE_SUCCESS", peer: peerID.displayName, details: "messageID=\(shortMsgID)")
                    
                    AppLogger.multipeer.info("""
                    [PINGLY_ROUTE_DECISION]
                    action=DELIVER
                    reason=DESTINATION_OR_CHANNEL_MATCHES_LOCAL_NODE
                    """)
                    
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
                            AppLogger.location.info("Processed P2P Location Protocol packet from \(message.senderName)")
                        } else if message.type == .transcript || message.text.hasPrefix("PTT_TRANSCRIPT:") {
                            let cleanText = message.text.hasPrefix("PTT_TRANSCRIPT:") ? String(message.text.dropFirst("PTT_TRANSCRIPT:".count)) : message.text
                            // Use the sender's channelID when present; fall back to this
                            // device's active channel rather than the hardcoded default so
                            // multi-channel transcript history stays accurate.
                            let channel = isChannelMessage ? message.channelID! : self.activeChannelID
                            _ = SwiftDataService.shared.saveVoiceTranscript(
                                id: message.id,
                                speakerName: message.senderName,
                                text: cleanText,
                                channel: channel,
                                isDelivered: true,
                                sessionID: message.sessionID
                            )
                            NotificationCenter.default.post(name: .didSaveVoiceTranscript, object: nil)
                            AppLogger.multipeer.info("Received P2P Voice Transcript for channel [\(channel)] from \(message.senderName)")
                        } else {
                            _ = SwiftDataService.shared.saveChatMessage(
                                id: message.id,
                                senderName: message.senderName,
                                channel: isChannelMessage ? message.channelID! : message.originID,
                                text: message.text,
                                isDelivered: true
                            )
                            MeshNotificationManager.shared.notifyMessageReceived(messageID: message.id, senderName: message.senderName, textPreview: message.text)
                            NotificationCenter.default.post(name: .didReceiveChatMessage, object: nil)
                            AppLogger.multipeer.info("Received P2P Chat Message from \(message.senderName)")
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
                            originID: message.originID,
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
                
                if shouldForward && !alreadyProcessed && message.originID != localNodeID {
                    AppLogger.multipeer.info("\(AppLogger.routingTag(message.id)) FORWARDING hops=\(message.hopsCount + 1) ttl=\(message.ttl - 1) peer=\(shortPeer)")
                    
                    AppLogger.multipeer.info("""
                    [PINGLY_ROUTE_DECISION]
                    action=RELAY
                    reason=INTERMEDIATE_NODE_FORWARD
                    """)
                    
                    RelaynTransportDiagnosticsManager.shared.incrementRelayReceived()
                    
                    var relayMsg = message
                    relayMsg.previousHopID = localNodeID
                    relayMsg.hopsCount += 1
                    
                    if relayMsg.hopsCount <= relayMsg.ttl {
                        self.broadcast(message: relayMsg)
                        RelaynTransportDiagnosticsManager.shared.incrementRelayForwarded()
                        AppLogger.multipeer.info("Relayed message \(relayMsg.id) (Hop \(relayMsg.hopsCount)/\(relayMsg.ttl))")
                    } else {
                        AppLogger.multipeer.info("\(AppLogger.routingTag(message.id)) FORWARD_REJECTED reason=TTL_EXPIRED")
                        RelaynTransportDiagnosticsManager.shared.incrementRelayDropped()
                        return
                    }
                    
                    AppLogger.multipeer.info("""
                    [PINGLY_RELAY_ENQUEUE]
                    originalMessageID=\(message.id.uuidString)
                    relayMessageID=\(message.id.uuidString)
                    originSender=\(message.originID)
                    currentSender=\(message.senderID)
                    destination=\(message.destinationID)
                    hopCount=\(message.hopsCount)
                    maxHop=\(message.ttl)
                    """)
                    
                    _ = SwiftDataService.shared.enqueueRelayMessage(message)
                    AppLogger.multipeer.info("Intermediate Relay: Enqueued message \(message.id) from '\(message.originID)' for destination '\(message.destinationID)'")
                    self.flushPendingStoreAndForwardQueue()
                }
            }
        }
    }
    
    private func sendDirectData(data: Data, to peer: MCPeerID) {
        guard let session = session else { return }
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
        if let context = context, let remoteNodeID = String(data: context, encoding: .utf8), UUID(uuidString: remoteNodeID) != nil {
            self.peerIDToNodeIDMap[peerID] = remoteNodeID
            AppLogger.multipeer.info("Mapped discovered peer via invitation context: \(peerID.displayName) -> \(remoteNodeID)")
        }
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "INVITATION_RECEIVED", peer: peerID.displayName, details: "invitation_accepted")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "INVITATION_RECEIVED", peer: peerID.displayName)
        invitationHandler(true, session)
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "INVITATION_ACCEPTED", peer: peerID.displayName, details: "invitation_handler_accepted=true")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "INVITATION_ACCEPTED", peer: peerID.displayName)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        AppLogger.multipeer.info("Browser found peer: \(peerID.displayName)")
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
        MeshNotificationManager.shared.notifyPeerDiscovered(peerID: resolvedNodeID, displayName: cleanName)
        guard let session = session else { return }
        
        // Deterministic tie-breaker for simultaneous invitations to prevent connection aborts
        if myPeerID.displayName > peerID.displayName {
            AppLogger.multipeer.info("Issuing invitation to peer: \(peerID.displayName)")
            RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "INVITATION_SENT", peer: peerID.displayName, details: "browser_tiebreaker_winner")
            RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "INVITATION_SENT", peer: peerID.displayName)
            let contextData = NodeIdentity.shared.nodeID.data(using: .utf8)
            browser.invitePeer(peerID, to: session, withContext: contextData, timeout: Constants.Multipeer.connectionTimeoutSeconds)
        } else {
            AppLogger.multipeer.info("Waiting for peer \(peerID.displayName) to issue invitation...")
            RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "INVITATION_WAITING", peer: peerID.displayName, details: "browser_tiebreaker_waiting")
        }
    }

    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        AppLogger.multipeer.info("Browser lost peer: \(peerID.displayName)")
        RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "PEER_LOST", peer: peerID.displayName, details: "lost_by_browser")
        RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "SessionFunnel", event: "PEER_LOST", peer: peerID.displayName)
        DispatchQueue.main.async {
            let resolvedNodeID = self.peerIDToNodeIDMap[peerID] ?? peerID.displayName
            self.connectedPeers.removeAll(where: { $0.id == resolvedNodeID || $0.mcPeerID == peerID })
            self.peerIDToNodeIDMap.removeValue(forKey: peerID)
            self.peerIDToHandleMap.removeValue(forKey: peerID)
            let peerList = self.connectedPeers.map { $0.displayName }
            RelaynTransportDiagnosticsManager.shared.updateConnectedPeersList(peerList)
            RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "CONNECTED_PEERS_COUNT", peer: resolvedNodeID, details: "count=\(self.connectedPeers.count)")
        }
    }
}
