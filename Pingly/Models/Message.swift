//
//  Message.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import CoreLocation

/// Envelope type discriminators for P2P network byte payloads
enum P2PMessageType: String, Codable {
    case chat = "CHAT"
    case transcript = "TRANSCRIPT"
    case location = "LOCATION"
    case ack = "ACK"
    case channelSync = "CHANNEL_SYNC"
    case locationRequest = "LOCATION_REQUEST"
    case locationResponse = "LOCATION_RESPONSE"
    case locationSharingStarted = "LOCATION_SHARING_STARTED"
    case locationSharingStopped = "LOCATION_SHARING_STOPPED"
    case relativePosition = "RELATIVE_POSITION"
    case locationExpired = "LOCATION_EXPIRED"
}

/// Discriminator for 1-hop link ACK vs end-to-end destination delivery ACK
enum ACKType: String, Codable {
    case hop = "HOP_ACK"
    case delivery = "DELIVERY_ACK"
}

/// End-to-end Delivery ACK payload
struct MessageDeliveryACK: Codable {
    let messageID: UUID
    let originID: String
    let destinationID: String
    let ackType: ACKType
    let currentNodeID: String
    let previousHopID: String?
    let hopsCount: Int
    let timestamp: Date
}

/// Emergency message drop & store-and-forward mesh payload model (Mesh V2 Envelope)
struct Message: Identifiable, Codable, Hashable {
    let id: UUID
    let originID: String
    let destinationID: String
    let senderID: String
    let senderName: String
    var senderAccountID: UUID?
    var senderDeviceID: UUID?
    var previousHopID: String?
    let channelID: String?
    let text: String
    let timestamp: Date
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let accuracy: Double?
    let isSOS: Bool
    let emergencyStatus: EmergencyStatus
    var hopsCount: Int
    var ttl: Int
    var type: P2PMessageType
    var protocolVersion: Int
    var authTag: String?
    
    init(
        id: UUID = UUID(),
        originID: String? = nil,
        destinationID: String = "BROADCAST",
        senderID: String,
        senderName: String,
        senderAccountID: UUID? = nil,
        senderDeviceID: UUID? = nil,
        previousHopID: String? = nil,
        channelID: String? = nil,
        text: String,
        timestamp: Date = Date(),
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil,
        accuracy: Double? = nil,
        isSOS: Bool = false,
        emergencyStatus: EmergencyStatus = .normal,
        hopsCount: Int = 0,
        ttl: Int = Constants.Emergency.broadcastTTL,
        type: P2PMessageType = .chat,
        protocolVersion: Int = Constants.Mesh.currentProtocolVersion,
        authTag: String? = nil
    ) {
        let finalOrigin = originID ?? senderID
        self.id = id
        self.originID = finalOrigin
        self.destinationID = destinationID
        self.senderID = senderID
        self.senderName = senderName
        self.senderAccountID = senderAccountID
        self.senderDeviceID = senderDeviceID
        self.previousHopID = previousHopID

        self.channelID = channelID
        self.text = text
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.isSOS = isSOS
        self.emergencyStatus = emergencyStatus
        self.hopsCount = hopsCount
        self.ttl = ttl
        self.type = type
        self.protocolVersion = protocolVersion
        self.authTag = authTag ?? MeshSecurityManager.shared.computeAuthTag(
            messageID: id,
            originID: finalOrigin,
            destinationID: destinationID,
            timestamp: timestamp,
            text: text
        )
    }


    
    var formattedLocation: String? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return String(format: "%.4f° N, %.4f° E", lat, lon)
    }
}


