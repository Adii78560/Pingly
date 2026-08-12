//
//  MultipeerService.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import MultipeerConnectivity
import Combine
import os

/// Production MultipeerConnectivity Service managing AirDrop/Wi-Fi/Bluetooth peer mesh networking
final class MultipeerService: NSObject, MultipeerServiceProtocol, ObservableObject {
    
    static let shared = MultipeerService()
    
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
    
    private var currentHandle: String = Constants.App.defaultUserHandle
    private var currentStatus: EmergencyStatus = .normal
    
    override init() {
        let storedHandle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        let deviceID = String(abs(storedHandle.hashValue ^ Int(Date().timeIntervalSinceReferenceDate)) % 10000)
        let peerDisplayName = "\(storedHandle)_\(deviceID)"
        self.currentHandle = storedHandle
        self.myPeerID = MCPeerID(displayName: peerDisplayName)
        super.init()
        setupSession()
    }


    
    private func setupSession() {
        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
    }
    
    func startAdvertisingAndBrowsing(userHandle: String, status: EmergencyStatus) {
        self.currentHandle = userHandle
        self.currentStatus = status
        
        stopAdvertisingAndBrowsing()
        
        let discoveryInfo: [String: String] = [
            "handle": userHandle,
            "status": status.rawValue
        ]
        
        let advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: discoveryInfo,
            serviceType: Constants.Multipeer.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        
        let browser = MCNearbyServiceBrowser(
            peer: myPeerID,
            serviceType: Constants.Multipeer.serviceType
        )
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        
        AppLogger.multipeer.info("Started Multipeer Advertising & Browsing for handle: \(userHandle)")
    }
    
    func stopAdvertisingAndBrowsing() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
    }
    
    func connectToPeer(peerID: MCPeerID) {
        guard let session = session, let browser = browser else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: Constants.Multipeer.connectionTimeoutSeconds)
        AppLogger.multipeer.info("Inviting peer: \(peerID.displayName)")
    }

    
    func broadcast(message: Message) {
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(message)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            AppLogger.multipeer.info("Broadcasted emergency message ID: \(message.id) to \(session.connectedPeers.count) peers")
        } catch {
            AppLogger.multipeer.error("Failed to broadcast message: \(error.localizedDescription)")
        }
    }
    
    func sendAudioStream(data: Data) {
        sendRawPTTPacket(data)
    }
    
    func sendRawPTTPacket(_ packet: Data) {
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        do {
            // PTT voice stream uses un-reliable mode for minimum latency
            try session.send(packet, toPeers: session.connectedPeers, with: .unreliable)
        } catch {
            AppLogger.multipeer.error("Failed to send PTT packet: \(error.localizedDescription)")
        }
    }
    func broadcastChannelSync(channelName: String) {
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        let invite = ChannelInvite(channelName: channelName, creatorHandle: currentHandle)
        do {
            let data = try JSONEncoder().encode(invite)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            AppLogger.multipeer.info("Broadcasted channel sync for \(channelName) to \(session.connectedPeers.count) peers")
        } catch {
            AppLogger.multipeer.error("Failed to send channel sync: \(error.localizedDescription)")
        }
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
            switch state {
            case .connected:
                AppLogger.multipeer.info("Peer connected: \(peerID.displayName)")
                if !self.connectedPeers.contains(where: { $0.id == peerID.displayName }) {
                    let newPeer = PeerDevice(
                        id: peerID.displayName,
                        displayName: peerID.displayName,
                        mcPeerID: peerID,
                        rssi: -55,
                        emergencyStatus: self.currentStatus,
                        isConnected: true
                    )
                    self.connectedPeers.append(newPeer)
                }
                self.flushPendingStoreAndForwardQueue(for: peerID)
            case .notConnected:
                AppLogger.multipeer.info("Peer disconnected: \(peerID.displayName)")
                self.connectedPeers.removeAll(where: { $0.id == peerID.displayName })
            case .connecting:
                AppLogger.multipeer.info("Connecting to peer: \(peerID.displayName)")
            @unknown default:
                break
            }
        }
    }
    
    /// Flushes queued offline store-and-forward messages when peer nodes enter network range.
    func flushPendingStoreAndForwardQueue(for peerID: MCPeerID? = nil) {
        Task { @MainActor in
            guard !connectedPeers.isEmpty else { return }
            
            let pendingList = SwiftDataService.shared.fetchPendingMessages()
            guard !pendingList.isEmpty else { return }
            
            for pending in pendingList {
                guard pending.retryCount < pending.maxRetries else {
                    AppLogger.multipeer.warning("Pending message \(pending.messageID) reached max retries (\(pending.maxRetries)). Skipping.")
                    continue
                }
                
                // Backoff delay check (wait 3s between retries if previously failed)
                if let lastAttempt = pending.lastAttemptTimestamp, Date().timeIntervalSince(lastAttempt) < 3.0 {
                    continue
                }
                
                SwiftDataService.shared.updatePendingMessageStatus(messageID: pending.messageID, status: .sending)
                
                let isTranscript = pending.text.hasPrefix("[")
                let msg = Message(
                    id: pending.messageID,
                    senderID: pending.senderName,
                    senderName: pending.senderName,
                    text: isTranscript ? pending.text : "[\(pending.channel)] \(pending.text)",
                    timestamp: pending.timestamp,
                    hopsCount: 0,
                    type: isTranscript ? .transcript : .chat
                )
                
                self.broadcast(message: msg)
                SwiftDataService.shared.updatePendingMessageStatus(messageID: pending.messageID, status: .waitingForACK)
                AppLogger.multipeer.info("Dispatched store-and-forward message \(pending.messageID) for '\(pending.recipientName)' (waiting for ACK)")
                
                // Schedule ACK timeout verification (5 seconds)
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    let checkList = SwiftDataService.shared.fetchPendingMessages()
                    if let item = checkList.first(where: { $0.messageID == pending.messageID }), item.status == .waitingForACK {
                        SwiftDataService.shared.updatePendingMessageStatus(messageID: pending.messageID, status: .failed)
                        AppLogger.multipeer.warning("ACK Timeout (5s) for pending message \(pending.messageID). Set status to FAILED.")
                    }
                }
            }
        }
    }

    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Try decoding as ChannelInvite first
        if let invite = try? JSONDecoder().decode(ChannelInvite.self, from: data), invite.type == "CHANNEL_SYNC" {
            NotificationCenter.default.post(
                name: .didReceiveChannelSync,
                object: self,
                userInfo: ["channelName": invite.channelName, "creator": invite.creatorHandle]
            )
            AppLogger.multipeer.info("Received channel sync invite: \(invite.channelName) from \(invite.creatorHandle)")
            return
        }
        
        // Try decoding as emergency / P2P text or voice transcript JSON Message next
        if let message = try? JSONDecoder().decode(Message.self, from: data) {
            DispatchQueue.main.async {
                let localUserHandle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
                
                // Handle incoming Delivery ACK frame
                if message.type == .ack {
                    SwiftDataService.shared.markPendingMessageAsACKed(messageID: message.id)
                    NotificationCenter.default.post(name: .didSaveVoiceTranscript, object: nil)
                    NotificationCenter.default.post(name: .didReceiveChatMessage, object: nil)
                    AppLogger.multipeer.info("Received MessageDeliveryACK for message ID \(message.id) from \(message.senderName)")
                    return
                }
                
                // Process chat message / voice transcript with Deduplication Engine
                let alreadyProcessed = SwiftDataService.shared.isMessageAlreadyProcessed(messageID: message.id)
                if !alreadyProcessed {
                    self.receivedMessageSubject.send(message)
                    
                    if message.text.hasPrefix("["), let closingBracket = message.text.firstIndex(of: "]") {
                        let channel = String(message.text[message.text.index(after: message.text.startIndex)..<closingBracket])
                        let body = String(message.text[message.text.index(after: closingBracket)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        _ = SwiftDataService.shared.saveVoiceTranscript(
                            speakerName: message.senderName,
                            text: body,
                            channel: channel,
                            isDelivered: true
                        )
                        NotificationCenter.default.post(name: .didSaveVoiceTranscript, object: nil)
                        AppLogger.multipeer.info("Received P2P Voice Transcript for channel [\(channel)] from \(message.senderName)")
                    } else {
                        _ = SwiftDataService.shared.saveChatMessage(
                            senderName: message.senderName,
                            channel: message.senderName,
                            text: message.text,
                            isDelivered: true
                        )
                        NotificationCenter.default.post(name: .didReceiveChatMessage, object: nil)
                        AppLogger.multipeer.info("Received P2P Chat Message from \(message.senderName)")
                    }
                } else {
                    AppLogger.multipeer.info("Deduplication Engine: Message \(message.id) already processed. Re-issuing ACK.")
                }
                
                // Send Delivery ACK back to sender
                let ackMessage = Message(
                    id: message.id,
                    senderID: localUserHandle,
                    senderName: localUserHandle,
                    text: "ACK",
                    timestamp: Date(),
                    hopsCount: 0,
                    type: .ack
                )
                self.broadcast(message: ackMessage)
            }
        } else {
            // Treat raw byte stream as live PTT audio chunk & post notification
            NotificationCenter.default.post(
                name: .didReceiveRawPTTPacket,
                object: self,
                userInfo: ["packet": data, "peerID": peerID]
            )
            DispatchQueue.main.async {
                self.receivedAudioDataSubject.send(data)
            }
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
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        AppLogger.multipeer.info("Browser found peer: \(peerID.displayName)")
        guard let session = session else { return }
        
        // Deterministic tie-breaker for simultaneous invitations to prevent connection aborts
        if myPeerID.displayName > peerID.displayName {
            AppLogger.multipeer.info("Issuing invitation to peer: \(peerID.displayName)")
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: Constants.Multipeer.connectionTimeoutSeconds)
        } else {
            AppLogger.multipeer.info("Waiting for peer \(peerID.displayName) to issue invitation...")
        }
    }

    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        AppLogger.multipeer.info("Browser lost peer: \(peerID.displayName)")
        DispatchQueue.main.async {
            self.connectedPeers.removeAll(where: { $0.id == peerID.displayName })
        }
    }
}
