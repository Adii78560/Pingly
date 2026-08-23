//
//  SDAudioSegment.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 21/08/26.
//

import Foundation
import SwiftData

/// SwiftData persistent model for recorded Walkie-Talkie audio segments.
@Model
final class SDAudioSegment {
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    var senderID: String
    var senderName: String
    var channelID: String
    var timestamp: Date
    var duration: Double
    var transcriptText: String?
    var localFileURL: String
    var directionRaw: String // "SENDER" or "RECEIVER"
    
    init(
        id: UUID = UUID(),
        sessionID: UUID,
        senderID: String,
        senderName: String,
        channelID: String,
        timestamp: Date = Date(),
        duration: Double,
        transcriptText: String? = nil,
        localFileURL: String,
        directionRaw: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.senderID = senderID
        self.senderName = senderName
        self.channelID = channelID
        self.timestamp = timestamp
        self.duration = duration
        self.transcriptText = transcriptText
        self.localFileURL = localFileURL
        self.directionRaw = directionRaw
    }
}
