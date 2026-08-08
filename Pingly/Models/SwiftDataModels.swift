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
    
    init(
        id: UUID = UUID(),
        speakerName: String,
        text: String,
        channel: String = "CH-1 EMERGENCY",
        timestamp: Date = Date(),
        isSynced: Bool = false
    ) {
        self.id = id
        self.speakerName = speakerName
        self.text = text
        self.channel = channel
        self.timestamp = timestamp
        self.isSynced = isSynced
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
    
    init(
        id: UUID = UUID(),
        senderName: String,
        channel: String = "CH-1 EMERGENCY",
        text: String,
        timestamp: Date = Date(),
        isSynced: Bool = false
    ) {
        self.id = id
        self.senderName = senderName
        self.channel = channel
        self.text = text
        self.timestamp = timestamp
        self.isSynced = isSynced
    }
}
