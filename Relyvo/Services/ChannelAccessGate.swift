//
//  ChannelAccessGate.swift
//  Relyvo
//
//  Centralized authorization layer for Channel communication.
//  Enforces the core product rule: Public channels are open, Private channels require membership.
//

import Foundation
import SwiftData

@MainActor
class ChannelAccessGate {
    static let shared = ChannelAccessGate()
    
    private init() {}
    
    /// The canonical decision method for whether a channel payload can be delivered locally or transmitted.
    /// - Parameters:
    ///   - channelID: The string identifier of the channel (e.g. "CH-1 EMERGENCY", "CH-PRIVATE").
    /// - Returns: `true` if the local user is authorized to participate in this channel.
    func isAuthorized(for channelID: String) -> Bool {
        // Predefined public channels are always authorized for all users.
        let publicChannels = ["CH-1 EMERGENCY", "CH-2 RESCUE MESH", "CH-3 MOUNTAIN OPS", "CH-4 GENERAL P2P"]
        if publicChannels.contains(channelID.uppercased()) {
            return true
        }
        
        // For private channels, we must check membership in SwiftData.
        let channelUUID = DirectConversationID.make(channelName: channelID)
        let localNodeID = NodeIdentity.shared.nodeID
        
        let descriptor = FetchDescriptor<SDChannelMember>(
            predicate: #Predicate { $0.channelID == channelUUID && $0.nodeID == localNodeID }
        )
        
        if let member = (try? SwiftDataService.shared.context.fetch(descriptor))?.first {
            return member.statusRaw == "ACCEPTED"
        }
        
        // If no membership record exists, or it's not ACCEPTED, deny access.
        // NOTE: If the user just created the channel and hasn't saved SDChannel/SDChannelMember yet, they won't have access. 
        // We will need to ensure the owner is immediately added as an ACCEPTED member during creation.
        return false
    }
}
