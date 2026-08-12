//
//  MeshSecurityManager.swift
//  Pingly
//
//  Created by Senior iOS Developer on 12/08/26.
//

import Foundation
import CryptoKit

/// Cryptographic envelope authentication & integrity manager using CryptoKit (HMAC-SHA256)
final class MeshSecurityManager {
    static let shared = MeshSecurityManager()
    
    // Static pre-shared mesh domain authentication key for off-grid P2P cluster verification
    private let meshAuthKey: SymmetricKey
    
    private init() {
        // Derive deterministic 256-bit symmetric key from mesh domain seed
        let seed = "PinglyOffGridMeshV2AuthSeed2026".data(using: .utf8)!
        let hash = SHA256.hash(data: seed)
        self.meshAuthKey = SymmetricKey(data: hash)
    }
    
    /// Computes HMAC-SHA256 signature tag over canonical packet attributes
    func computeAuthTag(messageID: UUID, originID: String, destinationID: String, timestamp: Date, text: String) -> String {
        let canonicalString = "\(messageID.uuidString):\(originID):\(destinationID):\(Int(timestamp.timeIntervalSince1970)):\(text)"
        let dataToSign = canonicalString.data(using: .utf8)!
        let mac = HMAC<SHA256>.authenticationCode(for: dataToSign, using: meshAuthKey)
        return Data(mac).base64EncodedString()
    }
    
    /// Verifies HMAC-SHA256 authentication tag for incoming Mesh V2 envelope
    func verify(message: Message) -> Bool {
        guard let tag = message.authTag, !tag.isEmpty else {
            // Optional legacy fallback if protocolVersion < 2
            return message.protocolVersion < 2
        }
        let expectedTag = computeAuthTag(
            messageID: message.id,
            originID: message.originID,
            destinationID: message.destinationID,
            timestamp: message.timestamp,
            text: message.text
        )
        return tag == expectedTag
    }
}
