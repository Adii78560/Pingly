//
//  SwiftDataModels.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import SwiftData

/// SwiftData persistent model for Walkie-Talkie voice transcripts partitioned by channel.
@Model
final class SDVoiceTranscript {
    @Attribute(.unique) var id: UUID
    var speakerName: String
    var text: String
    var channel: String
    var timestamp: Date
    var isSynced: Bool
    var isDelivered: Bool = false
    
    init(
        id: UUID = UUID(),
        speakerName: String,
        text: String,
        channel: String = "CH-1 EMERGENCY",
        timestamp: Date = Date(),
        isSynced: Bool = false,
        isDelivered: Bool = false
    ) {
        self.id = id
        self.speakerName = speakerName
        self.text = text
        self.channel = channel
        self.timestamp = timestamp
        self.isSynced = isSynced
        self.isDelivered = isDelivered
    }
}

/// SwiftData persistent model for P2P off-grid text & location messages partitioned by channel.
@Model
final class SDChatMessage {
    @Attribute(.unique) var id: UUID
    var senderName: String
    var channel: String
    var text: String
    var timestamp: Date
    var isSynced: Bool
    var isDelivered: Bool = false
    var messageTypeRaw: String = P2PMessageType.chat.rawValue
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var accuracy: Double?
    
    var type: P2PMessageType {
        get { P2PMessageType(rawValue: messageTypeRaw) ?? .chat }
        set { messageTypeRaw = newValue.rawValue }
    }
    
    init(
        id: UUID = UUID(),
        senderName: String,
        channel: String = "CH-1 EMERGENCY",
        text: String,
        timestamp: Date = Date(),
        isSynced: Bool = false,
        isDelivered: Bool = false,
        messageType: P2PMessageType = .chat,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil,
        accuracy: Double? = nil
    ) {
        self.id = id
        self.senderName = senderName
        self.channel = channel
        self.text = text
        self.timestamp = timestamp
        self.isSynced = isSynced
        self.isDelivered = isDelivered
        self.messageTypeRaw = messageType.rawValue
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
    }
}




/// Lifecycle status states for store-and-forward pending messages
enum PendingMessageStatus: String, Codable {
    case queued = "QUEUED"
    case sending = "SENDING"
    case waitingForACK = "WAITING_FOR_ACK"
    case failed = "FAILED"
    case acknowledged = "ACKNOWLEDGED"
}

/// Role discriminator distinguishing locally authored messages from intermediate relay items
enum QueueRole: String, Codable {
    case origin = "ORIGIN"
    case relay = "RELAY"
}

/// SwiftData persistent model for store-and-forward offline messages when peers are out of range.
@Model
final class SDPendingMessage {
    @Attribute(.unique) var id: UUID
    var messageID: UUID = UUID()
    var originID: String = ""
    var destinationID: String = "BROADCAST"
    var recipientName: String
    var senderName: String
    var previousHopID: String?
    var text: String
    var channel: String
    var timestamp: Date
    var expiresAt: Date = Date().addingTimeInterval(TimeInterval(Constants.Mesh.queueExpirationDays * 86400))
    var isSOS: Bool = false
    var priorityRaw: Int = 0 // 0 = Normal, 1 = Warning, 2 = Critical SOS
    var retryCount: Int = 0
    var statusRaw: String = PendingMessageStatus.queued.rawValue
    var queueRoleRaw: String = QueueRole.origin.rawValue
    var lastAttemptTimestamp: Date?
    var maxRetries: Int = 5
    var hopsCount: Int = 0
    var ttl: Int = Constants.Emergency.broadcastTTL
    
    var status: PendingMessageStatus {
        get { PendingMessageStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }
    
    var queueRole: QueueRole {
        get { QueueRole(rawValue: queueRoleRaw) ?? .origin }
        set { queueRoleRaw = newValue.rawValue }
    }
    
    init(
        id: UUID = UUID(),
        messageID: UUID = UUID(),
        originID: String? = nil,
        destinationID: String = "BROADCAST",
        recipientName: String,
        senderName: String,
        previousHopID: String? = nil,
        text: String,
        channel: String = "CH-1 EMERGENCY",
        timestamp: Date = Date(),
        expiresAt: Date? = nil,
        isSOS: Bool = false,
        priorityRaw: Int = 0,
        retryCount: Int = 0,
        status: PendingMessageStatus = .queued,
        queueRole: QueueRole = .origin,
        lastAttemptTimestamp: Date? = nil,
        maxRetries: Int = 5,
        hopsCount: Int = 0,
        ttl: Int = Constants.Emergency.broadcastTTL
    ) {
        self.id = id
        self.messageID = messageID
        self.originID = originID ?? senderName
        self.destinationID = destinationID
        self.recipientName = recipientName
        self.senderName = senderName
        self.previousHopID = previousHopID
        self.text = text
        self.channel = channel
        self.timestamp = timestamp
        self.expiresAt = expiresAt ?? timestamp.addingTimeInterval(TimeInterval(Constants.Mesh.queueExpirationDays * 86400))
        self.isSOS = isSOS
        self.priorityRaw = priorityRaw
        self.retryCount = retryCount
        self.statusRaw = status.rawValue
        self.queueRoleRaw = queueRole.rawValue
        self.lastAttemptTimestamp = lastAttemptTimestamp
        self.maxRetries = maxRetries
        self.hopsCount = hopsCount
        self.ttl = ttl
    }
}

/// SwiftData persistent model for Apple-authenticated user profile and unique username
@Model
final class SDUserProfile {
    @Attribute(.unique) var appleUserID: String
    @Attribute(.unique) var username: String
    var displayName: String
    var email: String?
    var createdAt: Date
    
    init(
        appleUserID: String,
        username: String,
        displayName: String,
        email: String? = nil,
        createdAt: Date = Date()
    ) {
        self.appleUserID = appleUserID
        self.username = username
        self.displayName = displayName
        self.email = email
        self.createdAt = createdAt
    }
}





