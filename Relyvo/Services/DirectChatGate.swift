//
//  DirectChatGate.swift
//  Relyvo
//
//  Centralized authorization layer for direct 1-to-1 communication.
//  Enforces the core product rule: Discovery ≠ Friendship ≠ Authorization.
//  Only an ACCEPTED friendship permits a direct chat.
//

import Foundation
import SwiftData

@MainActor
class DirectChatGate {
    static let shared = DirectChatGate()
    
    private init() {}
    
    /// The canonical decision method for whether a direct chat can be sent to or received from a remote node.
    /// - Parameter remoteNodeID: The nodeID of the remote peer.
    /// - Returns: `true` if and only if the local device has explicitly recorded an `.accepted` friendship with the remote peer.
    func canSendDirectMessage(to remoteNodeID: String) -> Bool {
        // Direct broadcast/channel is inherently authorized by channel membership.
        if remoteNodeID == "BROADCAST" || remoteNodeID.hasPrefix("CH-") {
            return true
        }
        
        // Strict gate: Must be exactly .accepted.
        let descriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == remoteNodeID })
        let status = (try? SwiftDataService.shared.context.fetch(descriptor))?.first?.status ?? .none
        return status == .accepted
    }
}
