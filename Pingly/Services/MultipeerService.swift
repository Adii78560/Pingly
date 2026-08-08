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
        self.currentHandle = storedHandle
        self.myPeerID = MCPeerID(displayName: storedHandle)
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
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        do {
            // PTT voice stream uses un-reliable mode for minimum latency
            try session.send(data, toPeers: session.connectedPeers, with: .unreliable)
        } catch {
            AppLogger.multipeer.error("Failed to send PTT audio stream chunk: \(error.localizedDescription)")
        }
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
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Try decoding as emergency JSON Message first
        if let message = try? JSONDecoder().decode(Message.self, from: data) {
            DispatchQueue.main.async {
                self.receivedMessageSubject.send(message)
            }
        } else {
            // Treat raw byte stream as live PTT audio chunk
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
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: Constants.Multipeer.connectionTimeoutSeconds)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        AppLogger.multipeer.info("Browser lost peer: \(peerID.displayName)")
        DispatchQueue.main.async {
            self.connectedPeers.removeAll(where: { $0.id == peerID.displayName })
        }
    }
}
