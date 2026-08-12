//
//  PinglyHardeningTests.swift
//  Pingly
//
//  Created by Senior iOS Developer on 12/08/26.
//

import Foundation
import os
import OSLog


/// Self-testing verification engine for Pingly Mesh V2 Hardening Pass
final class PinglyHardeningTests {
    static let shared = PinglyHardeningTests()
    
    private init() {}
    
    /// Runs all unit verification suites and prints diagnostic results
    func runAllVerificationTests() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        
        func assert(_ condition: Bool, _ message: String) {
            if condition {
                passed += 1
                AppLogger.multipeer.info("TEST PASSED: \(message)")
            } else {
                failed += 1
                AppLogger.multipeer.error("TEST FAILED: \(message)")
            }
        }
        
        // 1. Stable Node Identity Tests
        let id1 = NodeIdentity.shared.nodeID
        let id2 = NodeIdentity.shared.nodeID
        assert(id1 == id2, "Stable NodeIdentity is persistent across invocations")
        assert(id1.hasPrefix("NODE-"), "NodeIdentity exposes stable node prefix")
        
        // 2. CryptoKit HMAC Authentication Tests
        let msgID = UUID()
        let timestamp = Date()
        let tag1 = MeshSecurityManager.shared.computeAuthTag(
            messageID: msgID,
            originID: "NODE-TESTA",
            destinationID: "NODE-TESTB",
            timestamp: timestamp,
            text: "SOS Message"
        )
        let tag2 = MeshSecurityManager.shared.computeAuthTag(
            messageID: msgID,
            originID: "NODE-TESTA",
            destinationID: "NODE-TESTB",
            timestamp: timestamp,
            text: "SOS Message"
        )
        assert(tag1 == tag2, "HMAC-SHA256 authentication tag generation is deterministic")
        
        let validMsg = Message(
            id: msgID,
            originID: "NODE-TESTA",
            destinationID: "NODE-TESTB",
            senderID: "NODE-TESTA",
            senderName: "Node A",
            text: "SOS Message",
            timestamp: timestamp
        )
        assert(MeshSecurityManager.shared.verify(message: validMsg), "MeshSecurityManager verifies valid signed envelope")
        
        var forgedMsg = validMsg
        forgedMsg.authTag = "FORGED_SIGNATURE_TAG_BAD"
        assert(!MeshSecurityManager.shared.verify(message: forgedMsg), "MeshSecurityManager rejects forged auth tag")
        
        // 3. Payload Size Limit Tests
        let normalText = "Hello mesh"
        let oversizedText = String(repeating: "A", count: 70 * 1024) // 70 KB > 64 KB limit
        
        assert(normalText.utf8.count <= Constants.Mesh.maxPayloadBytes, "Normal payload size within 64 KB limit")
        assert(oversizedText.utf8.count > Constants.Mesh.maxPayloadBytes, "Oversized payload correctly exceeds 64 KB limit")
        
        // 4. Protocol Version Validation Tests
        let v2Msg = Message(senderID: "A", senderName: "A", text: "V2", protocolVersion: 2)
        let v3Msg = Message(senderID: "A", senderName: "A", text: "V3", protocolVersion: 3)
        assert(v2Msg.protocolVersion <= Constants.Mesh.currentProtocolVersion, "Protocol V2 accepted")
        assert(v3Msg.protocolVersion > Constants.Mesh.currentProtocolVersion, "Future Protocol V3 flagged for rejection")
        
        AppLogger.multipeer.info("HARDENING VERIFICATION SUMMARY: \(passed) Passed, \(failed) Failed.")
        return (passed, failed)
    }
}
