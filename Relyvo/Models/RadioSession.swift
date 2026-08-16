//
//  RadioSession.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation

/// PTT (Push-To-Talk) Radio call session model
struct RadioSession: Identifiable, Equatable {
    let id: String
    var channelName: String
    var activeSpeakerName: String?
    var isBroadcasting: Bool
    var isReceivingAudio: Bool
    var connectedPeersCount: Int
    var audioLevel: Float
    
    init(
        id: String = "Channel_1_Emergency",
        channelName: String = "CH-1 EMERGENCY",
        activeSpeakerName: String? = nil,
        isBroadcasting: Bool = false,
        isReceivingAudio: Bool = false,
        connectedPeersCount: Int = 0,
        audioLevel: Float = 0.0
    ) {
        self.id = id
        self.channelName = channelName
        self.activeSpeakerName = activeSpeakerName
        self.isBroadcasting = isBroadcasting
        self.isReceivingAudio = isReceivingAudio
        self.connectedPeersCount = connectedPeersCount
        self.audioLevel = audioLevel
    }
}
