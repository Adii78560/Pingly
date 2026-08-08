//
//  PeerDevice.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import MultipeerConnectivity

/// Peer discovery node state model representing nearby Pingly devices over BLE / Wi-Fi mesh
struct PeerDevice: Identifiable, Hashable {
    let id: String
    let displayName: String
    let mcPeerID: MCPeerID?
    var rssi: Int
    var estimatedDistanceMeters: Double
    var emergencyStatus: EmergencyStatus
    var lastSeen: Date
    var isConnected: Bool
    var batteryLevel: Float?
    
    init(
        id: String = UUID().uuidString,
        displayName: String,
        mcPeerID: MCPeerID? = nil,
        rssi: Int = -60,
        emergencyStatus: EmergencyStatus = .normal,
        lastSeen: Date = Date(),
        isConnected: Bool = false,
        batteryLevel: Float? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.mcPeerID = mcPeerID
        self.rssi = rssi
        self.estimatedDistanceMeters = Double.estimatedDistance(fromRSSI: rssi)
        self.emergencyStatus = emergencyStatus
        self.lastSeen = lastSeen
        self.isConnected = isConnected
        self.batteryLevel = batteryLevel
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: PeerDevice, rhs: PeerDevice) -> Bool {
        lhs.id == rhs.id
    }
}
