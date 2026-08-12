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

/// SwiftData persistent model for P2P off-grid text messages partitioned by channel.
@Model
final class SDChatMessage {
    @Attribute(.unique) var id: UUID
    var senderName: String
    var channel: String
    var text: String
    var timestamp: Date
    var isSynced: Bool
    var isDelivered: Bool = false
    
    init(
        id: UUID = UUID(),
        senderName: String,
        channel: String = "CH-1 EMERGENCY",
        text: String,
        timestamp: Date = Date(),
        isSynced: Bool = false,
        isDelivered: Bool = false
    ) {
        self.id = id
        self.senderName = senderName
        self.channel = channel
        self.text = text
        self.timestamp = timestamp
        self.isSynced = isSynced
        self.isDelivered = isDelivered
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

/// SwiftData persistent model for store-and-forward offline messages when peers are out of range.
@Model
final class SDPendingMessage {
    @Attribute(.unique) var id: UUID
    var messageID: UUID = UUID()
    var recipientName: String
    var senderName: String
    var text: String
    var channel: String
    var timestamp: Date
    var retryCount: Int = 0
    var statusRaw: String = PendingMessageStatus.queued.rawValue
    var lastAttemptTimestamp: Date?
    var maxRetries: Int = 5
    
    var status: PendingMessageStatus {
        get { PendingMessageStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }
    
    init(
        id: UUID = UUID(),
        messageID: UUID = UUID(),
        recipientName: String,
        senderName: String,
        text: String,
        channel: String = "CH-1 EMERGENCY",
        timestamp: Date = Date(),
        retryCount: Int = 0,
        status: PendingMessageStatus = .queued,
        lastAttemptTimestamp: Date? = nil,
        maxRetries: Int = 5
    ) {
        self.id = id
        self.messageID = messageID
        self.recipientName = recipientName
        self.senderName = senderName
        self.text = text
        self.channel = channel
        self.timestamp = timestamp
        self.retryCount = retryCount
        self.statusRaw = status.rawValue
        self.lastAttemptTimestamp = lastAttemptTimestamp
        self.maxRetries = maxRetries
    }
}


