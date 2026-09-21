//
//  SwiftDataModels.swift
//  Relayn
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
    var sessionID: UUID?
    
    init(
        id: UUID = UUID(),
        speakerName: String,
        text: String,
        channel: String = "CH-1 EMERGENCY",
        timestamp: Date = Date(),
        isSynced: Bool = false,
        isDelivered: Bool = false,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.speakerName = speakerName
        self.text = text
        self.channel = channel
        self.timestamp = timestamp
        self.isSynced = isSynced
        self.isDelivered = isDelivered
        self.sessionID = sessionID
    }
}

/// SwiftData persistent model for a Channel (Public or Private)
@Model
final class SDChannel {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var typeRaw: String // "PUBLIC" or "PRIVATE"
    var ownerNodeID: String
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        displayName: String,
        typeRaw: String = "PUBLIC",
        ownerNodeID: String = NodeIdentity.shared.nodeID,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.typeRaw = typeRaw
        self.ownerNodeID = ownerNodeID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// SwiftData persistent model for Channel Membership
@Model
final class SDChannelMember {
    @Attribute(.unique) var id: UUID
    var channelID: UUID
    var nodeID: String
    var statusRaw: String // "INVITED", "ACCEPTED", "DECLINED", "REVOKED"
    var joinedAt: Date?
    var keyVersion: Int
    
    init(
        id: UUID = UUID(),
        channelID: UUID,
        nodeID: String,
        statusRaw: String = "INVITED",
        joinedAt: Date? = nil,
        keyVersion: Int = 1
    ) {
        self.id = id
        self.channelID = channelID
        self.nodeID = nodeID
        self.statusRaw = statusRaw
        self.joinedAt = joinedAt
        self.keyVersion = keyVersion
    }
}

/// SwiftData persistent model for P2P off-grid text & location messages partitioned by channel.
@Model
final class SDChatMessage {
    @Attribute(.unique) var id: UUID
    var originID: String = ""
    var senderID: String = ""
    var destinationID: String = ""
    var senderName: String
    var channel: String
    var text: String
    var timestamp: Date
    var isSynced: Bool
    var isDelivered: Bool = false
    var isRead: Bool = false
    var messageTypeRaw: String = P2PMessageType.chat.rawValue
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var accuracy: Double?
    var conversationID: UUID = UUID()
    var relayHistory: [String] = []
    
    var type: P2PMessageType {
        get { P2PMessageType(rawValue: messageTypeRaw) ?? .chat }
        set { messageTypeRaw = newValue.rawValue }
    }
    
    init(
        id: UUID = UUID(),
        originID: String? = nil,
        senderID: String = NodeIdentity.shared.nodeID,
        destinationID: String? = nil,
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
        accuracy: Double? = nil,
        conversationID: UUID? = nil,
        relayHistory: [String] = []
    ) {
        self.id = id
        self.senderID = senderID
        self.originID = originID ?? senderID
        self.destinationID = destinationID ?? channel
        self.senderName = senderName
        self.channel = channel
        self.text = text
        self.timestamp = timestamp
        self.isSynced = isSynced
        self.isDelivered = isDelivered
        self.isRead = false
        self.messageTypeRaw = messageType.rawValue
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.relayHistory = relayHistory
        
        let finalOrigin = originID ?? senderID
        let finalDest = destinationID ?? channel
        if let explicitConv = conversationID {
            self.conversationID = explicitConv
        } else if finalDest == "BROADCAST" || channel == "BROADCAST" {
            self.conversationID = DirectConversationID.make(channelName: "BROADCAST")
        } else if channel.hasPrefix("CH-") {
            self.conversationID = DirectConversationID.make(channelName: channel)
        } else {
            self.conversationID = DirectConversationID.make(nodeA: finalOrigin, nodeB: finalDest)
        }
    }
}




/// Lifecycle status states for store-and-forward pending messages
/// Lifecycle status states for store-and-forward pending messages
enum PendingMessageStatus: String, Codable {
    case created = "CREATED"
    case queued = "QUEUED"
    case transmitting = "TRANSMITTING"
    case relayed = "RELAYED"
    case sent = "SENT"
    case delivered = "DELIVERED"
    case read = "READ"
    case failed = "FAILED"
    case expired = "EXPIRED"
    case cancelled = "CANCELLED"
    
    // Legacy Raw Value Aliases for Backward Compatibility
    static var pending: PendingMessageStatus { .queued }
    static var sending: PendingMessageStatus { .transmitting }
    static var waitingForACK: PendingMessageStatus { .sent }
    static var acknowledged: PendingMessageStatus { .delivered }
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
    var relayHistory: [String] = []
    var text: String
    var channel: String
    var conversationID: UUID = UUID()
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
    var messageTypeRaw: String = P2PMessageType.chat.rawValue
    
    // Delivery Lifecycle Timestamps & Receipts
    var queuedAt: Date?
    var transmittingAt: Date?
    var sentAt: Date?
    var deliveredAt: Date?
    var failedAt: Date?
    var deliveryReceiptID: String?
    var notificationSent: Bool = false
    
    var status: PendingMessageStatus {
        get {
            switch statusRaw {
            case "SENDING": return .transmitting
            case "WAITING_FOR_ACK": return .sent
            case "ACKNOWLEDGED": return .delivered
            default: return PendingMessageStatus(rawValue: statusRaw) ?? .queued
            }
        }
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
        relayHistory: [String] = [],
        text: String,
        channel: String = "CH-1 EMERGENCY",
        conversationID: UUID? = nil,
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
        ttl: Int = Constants.Emergency.broadcastTTL,
        queuedAt: Date? = Date(),
        transmittingAt: Date? = nil,
        sentAt: Date? = nil,
        deliveredAt: Date? = nil,
        failedAt: Date? = nil,
        deliveryReceiptID: String? = nil,
        notificationSent: Bool = false
    ) {
        self.id = id
        self.messageID = messageID
        self.originID = originID ?? senderName
        self.destinationID = destinationID
        self.recipientName = recipientName
        self.senderName = senderName
        self.previousHopID = previousHopID
        self.relayHistory = relayHistory
        self.text = text
        self.channel = channel
        
        let finalOrigin = originID ?? senderName
        if let explicitConv = conversationID {
            self.conversationID = explicitConv
        } else if destinationID == "BROADCAST" || channel == "BROADCAST" {
            self.conversationID = DirectConversationID.make(channelName: "BROADCAST")
        } else if channel.hasPrefix("CH-") {
            self.conversationID = DirectConversationID.make(channelName: channel)
        } else {
            self.conversationID = DirectConversationID.make(nodeA: finalOrigin, nodeB: destinationID)
        }
        
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
        self.queuedAt = queuedAt
        self.transmittingAt = transmittingAt
        self.sentAt = sentAt
        self.deliveredAt = deliveredAt
        self.failedAt = failedAt
        self.deliveryReceiptID = deliveryReceiptID
        self.notificationSent = notificationSent
    }
}

/// SwiftData persistent model for local notification events and deduplication state
@Model
final class SDNotificationEvent {
    @Attribute(.unique) var id: UUID
    var eventTypeRaw: String
    var messageID: UUID?
    var peerID: String?
    var timestamp: Date
    var title: String
    var body: String
    var deliveredToNotificationCenter: Bool
    var acknowledged: Bool
    @Attribute(.unique) var deduplicationKey: String
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        eventTypeRaw: String,
        messageID: UUID? = nil,
        peerID: String? = nil,
        timestamp: Date = Date(),
        title: String,
        body: String,
        deliveredToNotificationCenter: Bool = true,
        acknowledged: Bool = false,
        deduplicationKey: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.eventTypeRaw = eventTypeRaw
        self.messageID = messageID
        self.peerID = peerID
        self.timestamp = timestamp
        self.title = title
        self.body = body
        self.deliveredToNotificationCenter = deliveredToNotificationCenter
        self.acknowledged = acknowledged
        self.deduplicationKey = deduplicationKey
        self.createdAt = createdAt
    }
}

/// SwiftData persistent model for Apple-authenticated user profile and unique username
@Model
final class SDUserProfile {
    @Attribute(.unique) var accountID: UUID
    @Attribute(.unique) var appleUserID: String
    @Attribute(.unique) var username: String
    var displayName: String
    var email: String?
    var createdAt: Date
    var updatedAt: Date
    
    init(
        accountID: UUID = UUID(),
        appleUserID: String,
        username: String,
        displayName: String,
        email: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.accountID = accountID
        self.appleUserID = appleUserID
        self.username = username
        self.displayName = displayName
        self.email = email
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// SwiftData persistent model tracking location sharing sessions and coordinates between two mesh peers
@Model
final class SDLocationShareSession {
    @Attribute(.unique) var id: UUID
    var localPeerID: String
    var remotePeerID: String
    var remoteDisplayName: String
    var startedAt: Date
    var expiresAt: Date?
    var isActive: Bool
    var isSharingLocal: Bool
    var isSharingRemote: Bool
    var lastLocalLatitude: Double?
    var lastLocalLongitude: Double?
    var lastLocalAccuracy: Double?
    var lastLocalTimestamp: Date?
    var lastRemoteLatitude: Double?
    var lastRemoteLongitude: Double?
    var lastRemoteAccuracy: Double?
    var lastRemoteSpeed: Double?
    var lastRemoteCourse: Double?
    var lastRemoteTimestamp: Date?
    var sequenceNumber: Int
    var lastRemoteSequenceNumber: Int?
    var stateRaw: String
    
    init(
        id: UUID = UUID(),
        localPeerID: String,
        remotePeerID: String,
        remoteDisplayName: String,
        startedAt: Date = Date(),
        expiresAt: Date? = nil,
        isActive: Bool = true,
        isSharingLocal: Bool = false,
        isSharingRemote: Bool = false,
        lastLocalLatitude: Double? = nil,
        lastLocalLongitude: Double? = nil,
        lastLocalAccuracy: Double? = nil,
        lastLocalTimestamp: Date? = nil,
        lastRemoteLatitude: Double? = nil,
        lastRemoteLongitude: Double? = nil,
        lastRemoteAccuracy: Double? = nil,
        lastRemoteSpeed: Double? = nil,
        lastRemoteCourse: Double? = nil,
        lastRemoteTimestamp: Date? = nil,
        sequenceNumber: Int = 0,
        lastRemoteSequenceNumber: Int? = nil,
        stateRaw: String = "ACTIVE"
    ) {
        self.id = id
        self.localPeerID = localPeerID
        self.remotePeerID = remotePeerID
        self.remoteDisplayName = remoteDisplayName
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.isActive = isActive
        self.isSharingLocal = isSharingLocal
        self.isSharingRemote = isSharingRemote
        self.lastLocalLatitude = lastLocalLatitude
        self.lastLocalLongitude = lastLocalLongitude
        self.lastLocalAccuracy = lastLocalAccuracy
        self.lastLocalTimestamp = lastLocalTimestamp
        self.lastRemoteLatitude = lastRemoteLatitude
        self.lastRemoteLongitude = lastRemoteLongitude
        self.lastRemoteAccuracy = lastRemoteAccuracy
        self.lastRemoteSpeed = lastRemoteSpeed
        self.lastRemoteCourse = lastRemoteCourse
        self.lastRemoteTimestamp = lastRemoteTimestamp
        self.sequenceNumber = sequenceNumber
        self.lastRemoteSequenceNumber = lastRemoteSequenceNumber
        self.stateRaw = stateRaw
    }
}

/// SwiftData persistent model for user GPS breadcrumb tracking sessions
@Model
final class SDBreadcrumbTrack {
    @Attribute(.unique) var id: UUID
    var name: String
    var startedAt: Date
    var endedAt: Date?
    var isActive: Bool
    var totalDistanceMeters: Double
    var pointsCount: Int
    var startLatitude: Double?
    var startLongitude: Double?
    var startAltitude: Double?
    
    init(
        id: UUID = UUID(),
        name: String = "Track \(Date().formatted(date: .abbreviated, time: .shortened))",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        isActive: Bool = true,
        totalDistanceMeters: Double = 0.0,
        pointsCount: Int = 0,
        startLatitude: Double? = nil,
        startLongitude: Double? = nil,
        startAltitude: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isActive = isActive
        self.totalDistanceMeters = totalDistanceMeters
        self.pointsCount = pointsCount
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.startAltitude = startAltitude
    }
}

/// SwiftData persistent model for individual GPS breadcrumb points along a track
@Model
final class SDBreadcrumbPoint {
    @Attribute(.unique) var id: UUID
    var trackID: UUID
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    var accuracy: Double
    var speed: Double?
    var course: Double?
    var heading: Double?
    var timestamp: Date
    var sequenceIndex: Int
    
    init(
        id: UUID = UUID(),
        trackID: UUID,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        accuracy: Double = 5.0,
        speed: Double? = nil,
        course: Double? = nil,
        heading: Double? = nil,
        timestamp: Date = Date(),
        sequenceIndex: Int = 0
    ) {
        self.id = id
        self.trackID = trackID
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.speed = speed
        self.course = course
        self.heading = heading
        self.timestamp = timestamp
        self.sequenceIndex = sequenceIndex
    }
}

/// SwiftData persistent model tracking downloaded or bundled offline vector/topological map regions
@Model
final class SDOfflineMapRegion {
    @Attribute(.unique) var id: String
    var name: String
    var version: String? = "1.0"
    var stateOrRegion: String
    var minLatitude: Double
    var minLongitude: Double
    var maxLatitude: Double
    var maxLongitude: Double
    var minZoom: Int
    var maxZoom: Int
    var fileSizeBytes: Int64
    var isDownloaded: Bool
    var downloadedAt: Date?
    var localFilePath: String?
    
    init(
        id: String,
        name: String,
        version: String? = "1.0",
        stateOrRegion: String,
        minLatitude: Double,
        minLongitude: Double,
        maxLatitude: Double,
        maxLongitude: Double,
        minZoom: Int = 0,
        maxZoom: Int = 16,
        fileSizeBytes: Int64 = 0,
        isDownloaded: Bool = false,
        downloadedAt: Date? = nil,
        localFilePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.stateOrRegion = stateOrRegion
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.fileSizeBytes = fileSizeBytes
        self.isDownloaded = isDownloaded
        self.downloadedAt = downloadedAt
        self.localFilePath = localFilePath
    }
}

enum FriendStatus: String, Codable {
    case none
    case requestSent
    case requestReceived
    case accepted
    case declined
}

/// SwiftData persistent model tracking a persistent friend on the radar
@Model
final class SDFriend {
    @Attribute(.unique) var nodeID: String
    var handle: String
    var dateAdded: Date
    
    // Friend protocol properties (Optional for safe lightweight migration)
    var statusRaw: String? = FriendStatus.none.rawValue
    var requestID: UUID? = nil
    
    var status: FriendStatus {
        get { FriendStatus(rawValue: statusRaw ?? "none") ?? .none }
        set { statusRaw = newValue.rawValue }
    }
    
    init(nodeID: String, handle: String, dateAdded: Date = Date(), status: FriendStatus = .none, requestID: UUID? = nil) {
        self.nodeID = nodeID
        self.handle = handle
        self.dateAdded = dateAdded
        self.statusRaw = status.rawValue
        self.requestID = requestID
    }
}
