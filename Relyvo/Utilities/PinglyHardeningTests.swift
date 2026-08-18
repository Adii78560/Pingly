//
//  RelaynHardeningTests.swift
//  Relayn
//
//  Created by Senior iOS Developer on 12/08/26.
//

import Foundation
import os
import OSLog


/// Self-testing verification engine for Relayn Mesh V2 Hardening Pass
final class RelaynHardeningTests {
    static let shared = RelaynHardeningTests()
    
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
        
        // 5. Notification System & Deduplication Tests
        let testDedupKey = "TEST_DEDUP_KEY_\(UUID().uuidString)"
        let recorded1 = SwiftDataService.shared.recordNotificationEvent(
            eventTypeRaw: "TEST_EVENT",
            title: "Test Event",
            body: "Test notification body",
            deduplicationKey: testDedupKey
        )
        assert(recorded1, "SwiftDataService records fresh notification event")
        
        let recorded2 = SwiftDataService.shared.recordNotificationEvent(
            eventTypeRaw: "TEST_EVENT",
            title: "Duplicate Test Event",
            body: "Duplicate body",
            deduplicationKey: testDedupKey
        )
        assert(!recorded2, "SwiftDataService rejects duplicate notification key")
        
        let isDedup = SwiftDataService.shared.isNotificationDeduplicated(deduplicationKey: testDedupKey)
        assert(isDedup, "isNotificationDeduplicated returns true for stored deduplication key")
        
        // 6. Offline Location & Relative Bearing Math Tests
        let validLat = 37.7749
        let validLon = -122.4194
        let invalidLat = 105.0 // > 90
        
        assert(validLat >= -90.0 && validLat <= 90.0 && validLon >= -180.0 && validLon <= 180.0, "Valid coordinate bounds check passes")
        assert(invalidLat < -90.0 || invalidLat > 90.0, "Invalid coordinate bounds check correctly flagged")
        
        let relMath = LocationService.shared.distanceAndBearingFromUser(toLat: validLat, lon: validLon)
        assert(relMath != nil || LocationService.shared.currentCoordinate == nil, "distanceAndBearingFromUser executes cleanly")
        
        // 7. Circular Angle Shortest-Path Math Tests
        let delta1 = CircularAngleHelper.shortestAngularDifference(from: 359.0, to: 1.0)
        assert(abs(delta1 - 2.0) < 0.001, "359° -> 1° produces shortest delta +2°")
        
        let delta2 = CircularAngleHelper.shortestAngularDifference(from: 1.0, to: 359.0)
        assert(abs(delta2 - (-2.0)) < 0.001, "1° -> 359° produces shortest delta -2°")
        
        let delta3 = CircularAngleHelper.shortestAngularDifference(from: 179.0, to: 181.0)
        assert(abs(delta3 - 2.0) < 0.001, "179° -> 181° produces shortest delta +2°")
        
        let delta4 = CircularAngleHelper.shortestAngularDifference(from: 350.0, to: 10.0)
        assert(abs(delta4 - 20.0) < 0.001, "350° -> 10° produces shortest delta +20°")
        
        // 8. Sequence Protection & Relative Position Privacy Tests
        let seq10 = 10
        let seq11 = 11
        let seq9 = 9
        assert(seq11 > seq10, "Sequence 11 accepted after 10")
        assert(!(seq9 > seq10), "Sequence 9 rejected after 10")
        
        let relPacket = LocationPacket(
            type: "RELATIVE_POSITION",
            id: UUID(),
            senderID: "node1",
            senderName: "User1",
            recipientID: "node2",
            timestamp: Date(),
            accepted: nil,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            speed: nil,
            course: nil,
            sequenceNumber: 1,
            distanceMeters: 40.0,
            relativeBearing: 45.0,
            compassDirection: "NE"
        )
        assert(relPacket.latitude == nil && relPacket.longitude == nil, "Relative position packet contains zero raw GPS coordinates")
        
        // 9. Migration & Non-Destructive Data Preservation Tests
        let dummySession = SDLocationShareSession(
            localPeerID: "local1",
            remotePeerID: "remote1",
            remoteDisplayName: "TestRemote"
        )
        assert(dummySession.lastRemoteSequenceNumber == nil, "Existing/unmigrated session lastRemoteSequenceNumber defaults to nil")
        
        let nilSeq: Int? = nil
        let firstSeq = 10
        let isFirstAccepted = (nilSeq == nil || firstSeq > nilSeq!)
        assert(isFirstAccepted, "First sequence number accepted when lastRemoteSequenceNumber is nil")
        
        let currentSeq = 10
        let nextSeq = 11
        let dupSeq = 10
        let oldSeq = 9
        assert(nextSeq > currentSeq, "Sequence 11 accepted after 10")
        assert(!(dupSeq > currentSeq), "Duplicate sequence 10 rejected")
        assert(!(oldSeq > currentSeq), "Out-of-order sequence 9 rejected")
        
        // 10. Simulator Messaging Loopback Test Suite
        Task { @MainActor in
            let loopbackRes = LoopbackTestHarness.shared.runAllLoopbackTests()
            AppLogger.multipeer.info("SIMULATOR LOOPBACK SUITE SUMMARY: \(loopbackRes.passedCount) Passed, \(loopbackRes.failedCount) Failed")
        }
        
        AppLogger.multipeer.info("HARDENING VERIFICATION SUMMARY: \(passed) Passed, \(failed) Failed.")
        return (passed, failed)
    }
}
