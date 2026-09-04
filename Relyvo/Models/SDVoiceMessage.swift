//
//  SDVoiceMessage.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 26/08/26.
//

import Foundation
import SwiftData

/// SwiftData persistent model for recorded Walkie-Talkie voice notes in channel history.
@Model
final class SDVoiceMessage: Identifiable {
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    var channelID: String
    var senderID: String
    var senderAlias: String
    var timestamp: Date
    var duration: Double
    var audioFilePath: String
    var isPlayed: Bool
    var directionRaw: String // "SENDER" or "RECEIVER"
    var isDelivered: Bool
    
    var isSender: Bool {
        return directionRaw == "SENDER"
    }
    
    init(
        id: UUID = UUID(),
        sessionID: UUID = UUID(),
        channelID: String = "CH-1 EMERGENCY",
        senderID: String = NodeIdentity.shared.nodeID,
        senderAlias: String = "Survivor",
        timestamp: Date = Date(),
        duration: Double = 0.0,
        audioFilePath: String,
        isPlayed: Bool = false,
        directionRaw: String = "SENDER",
        isDelivered: Bool = true
    ) {
        self.id = id
        self.sessionID = sessionID
        self.channelID = channelID
        self.senderID = senderID
        self.senderAlias = senderAlias
        self.timestamp = timestamp
        self.duration = duration
        self.audioFilePath = audioFilePath
        self.isPlayed = isPlayed
        self.directionRaw = directionRaw
        self.isDelivered = isDelivered
    }
}

/// In-memory immutable presentation model for voice message bubbles in SwiftUI channel timeline.
struct VoiceMessage: Identifiable, Equatable, Hashable {
    let id: UUID
    let sessionID: UUID
    let channelID: String
    let senderID: String
    let senderAlias: String
    let timestamp: Date
    let duration: Double
    let audioFilePath: String
    var isPlayed: Bool
    let directionRaw: String
    let isDelivered: Bool
    
    var isSender: Bool { directionRaw == "SENDER" }
    
    var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, max(1, secs))
    }
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}
