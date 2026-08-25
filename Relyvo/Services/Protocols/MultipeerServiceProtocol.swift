//
//  MultipeerServiceProtocol.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import MultipeerConnectivity
import Combine

/// Interface for P2P Multipeer Connectivity Service
protocol MultipeerServiceProtocol: AnyObject {
    var myPeerID: MCPeerID { get }
    /// The currently active Walkie-Talkie channel ID used to gate incoming channel broadcasts.
    var activeChannelID: String { get set }
    var connectedPeersPublisher: AnyPublisher<[PeerDevice], Never> { get }
    var receivedMessagePublisher: AnyPublisher<Message, Never> { get }
    var receivedAudioDataPublisher: AnyPublisher<Data, Never> { get }
    
    func startAdvertisingAndBrowsing(userHandle: String, status: EmergencyStatus)
    func stopAdvertisingAndBrowsing()
    func teardownAndResetSession()
    func connectToPeer(peerID: MCPeerID)
    func broadcast(message: Message)
    func sendAudioStream(data: Data)
}

