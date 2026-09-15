//
//  DirectConversationID.swift
//  Relyvo
//
//  Helper to deterministically generate a conversation UUID for 1-to-1 chats
//  between two NodeIdentity UUID strings.
//

import Foundation
import CryptoKit

enum DirectConversationID {
    
    /// Generates a deterministic UUID for a direct 1-on-1 conversation.
    ///
    /// - Parameters:
    ///   - localNodeID: The canonical UUID string of the local device.
    ///   - remoteNodeID: The canonical UUID string of the remote device.
    /// - Returns: A globally unique, deterministic UUID representing the conversation.
    static func make(nodeA: String, nodeB: String) -> UUID {
        // 1. Normalize both UUIDs to standard lowercase format to ignore formatting quirks.
        let normA = nodeA.lowercased()
        let normB = nodeB.lowercased()
        
        // 2. Sort lexicographically to ensure A + B == B + A.
        let sorted = [normA, normB].sorted()
        
        // 3. Concatenate and hash the sorted pair using SHA256.
        let combinedString = sorted.joined(separator: "_")
        return makeDeterministicUUID(from: combinedString)
    }
    
    /// Generates a deterministic UUID for a channel conversation.
    ///
    /// - Parameter channelName: The name of the channel.
    /// - Returns: A globally unique, deterministic UUID representing the channel conversation.
    static func make(channelName: String) -> UUID {
        return makeDeterministicUUID(from: channelName.uppercased())
    }
    
    private static func makeDeterministicUUID(from string: String) -> UUID {
        guard let data = string.data(using: .utf8) else {
            return UUID()
        }
        
        let hash = SHA256.hash(data: data)
        let hashBytes = Array(hash)
        
        guard hashBytes.count >= 16 else {
            return UUID()
        }
        
        return UUID(uuid: (
            hashBytes[0], hashBytes[1], hashBytes[2], hashBytes[3],
            hashBytes[4], hashBytes[5], hashBytes[6], hashBytes[7],
            hashBytes[8], hashBytes[9], hashBytes[10], hashBytes[11],
            hashBytes[12], hashBytes[13], hashBytes[14], hashBytes[15]
        ))
    }
}
