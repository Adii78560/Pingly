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
    var sessionID: UUID?
    let conversationID: UUID
    var relayHistory: [UUID]
    
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
        authTag: String? = nil,
        sessionID: UUID? = nil,
        conversationID: UUID? = nil,
        relayHistory: [UUID] = []
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
        self.sessionID = sessionID
        
        if let explicitConvID = conversationID {
            self.conversationID = explicitConvID
        } else if let channel = channelID {
            self.conversationID = DirectConversationID.make(channelName: channel)
        } else if destinationID == "BROADCAST" {
            // General mesh broadcast
            self.conversationID = DirectConversationID.make(channelName: "BROADCAST")
        } else {
            self.conversationID = DirectConversationID.make(nodeA: finalOrigin, nodeB: destinationID)
        }
        self.relayHistory = relayHistory
    }


    
    var formattedLocation: String? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return String(format: "%.4f° N, %.4f° E", lat, lon)
    }
}

/// Model representing a high-priority emergency SOS alert received over the mesh.
struct SOSAlertPayload: Identifiable, Equatable {
    let id: UUID
    let senderID: String
    let senderAlias: String
    let timestamp: Date
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let accuracy: Double?
    let channelID: String
    let text: String
    
    var formattedCoordinates: String {
        guard let lat = latitude, let lon = longitude else { return "Coordinates Unavailable" }
        return String(format: "%.4f° N, %.4f° E", lat, lon)
    }
    
    func distanceAndBearing(from currentLocation: CLLocation?) -> (distanceString: String, bearingString: String)? {
        guard let lat = latitude, let lon = longitude, let current = currentLocation else { return nil }
        let target = CLLocation(latitude: lat, longitude: lon)
        let distanceMeters = current.distance(from: target)
        
        let distStr: String
        if distanceMeters < 1000 {
            distStr = String(format: "%.0fm away", distanceMeters)
        } else {
            distStr = String(format: "%.1fkm away", distanceMeters / 1000.0)
        }
        
        // Bearing Calculation
        let lat1 = current.coordinate.latitude * .pi / 180.0
        let lon1 = current.coordinate.longitude * .pi / 180.0
        let lat2 = lat * .pi / 180.0
        let lon2 = lon * .pi / 180.0
        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var radiansBearing = atan2(y, x)
        if radiansBearing < 0.0 { radiansBearing += 2 * .pi }
        let degrees = radiansBearing * 180.0 / .pi
        
        let compass = ["N", "NE", "E", "SE", "S", "SW", "W", "NW", "N"]
        let index = Int(round(degrees.truncatingRemainder(dividingBy: 360) / 45))
        let bearingStr = "\(Int(degrees))° \(compass[index])"
        
        return (distStr, bearingStr)
    }
}


