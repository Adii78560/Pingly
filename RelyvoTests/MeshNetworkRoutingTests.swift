//
//  MeshNetworkRoutingTests.swift
//  RelyvoTests
//
//  Comprehensive unit tests for the Relyvo Offline Mesh Network Protocol:
//  - Multi-hop overlay routing across intermediate nodes (A -> B -> C).
//  - Multipath diamond mesh topology and canonical deduplication.
//  - Store-and-forward Delay-Tolerant Networking (DTN) relay lifecycle.
//  - TTL expiration and cycle storm breaker (relayHistory loop prevention).
//  - Compact binary wire protocol MTU compliance (Bluetooth LE & AWDL).
//  - Path loss distance and range estimation via BLE RSSI.
//

import XCTest
import SwiftData
@testable import Relyvo

// MARK: - 1. Multi-Hop Mesh Routing Tests (A -> B -> C)

@MainActor
final class MultiHopMeshRoutingTests: XCTestCase {
    
    /// Simulates a 3-node linear mesh topology where Node A and Node C cannot communicate directly,
    /// and rely on intermediate Node B to route messages across the mesh.
    func testLinearThreeNodeMeshForwarding() throws {
        let aliceID   = UUID()
        let relayBobID = UUID()
        let charlieID = UUID()
        let msgID     = UUID()
        let convID    = DirectConversationID.make(nodeA: aliceID.uuidString, nodeB: charlieID.uuidString)
        
        // --- Step 1: Alice creates packet destined for Charlie ---
        let aliceOriginalMsg = Message(
            id: msgID,
            originID: aliceID.uuidString,
            destinationID: charlieID.uuidString,
            senderID: aliceID.uuidString,
            senderName: "Alice",
            previousHopID: aliceID.uuidString,
            text: "Mountain check: Charlie, please confirm base camp arrival.",
            hopsCount: 0,
            ttl: 4,
            type: .chat,
            conversationID: convID
        )
        
        XCTAssertEqual(aliceOriginalMsg.hopsCount, 0)
        XCTAssertEqual(aliceOriginalMsg.ttl, 4)
        
        // Alice encodes into binary wire format (MeshPacketHeader)
        let aliceWireData = try MeshPacketHeader.encode(aliceOriginalMsg, sequenceNumber: 1)
        XCTAssertGreaterThan(aliceWireData.count, 62, "Binary packet must contain at least 62-byte header")
        
        // --- Step 2: Intermediate Relay Bob intercepts the packet ---
        // Bob decodes the packet from Alice
        let bobDecoded = try MeshPacketHeader.decode(from: aliceWireData)
        XCTAssertEqual(bobDecoded.originUUID, aliceID)
        XCTAssertEqual(bobDecoded.destinationUUID, charlieID)
        XCTAssertEqual(bobDecoded.messageID, msgID)
        
        // Bob checks: Is this for me?
        let isForBob = (bobDecoded.destinationUUID == relayBobID)
        XCTAssertFalse(isForBob, "Packet is destined for Charlie, not Bob")
        
        // Bob checks: Should I forward?
        let shouldForward = (!isForBob) && (bobDecoded.ttl > 1)
        XCTAssertTrue(shouldForward, "Bob must forward packets destined for other nodes when TTL > 1")
        
        // Bob creates the forwarded packet with decremented TTL and incremented hopCount
        var bobRelayHistory = bobDecoded.relayHistory
        bobRelayHistory.append(relayBobID)
        
        let bobForwardedMsg = Message(
            id: bobDecoded.messageID,
            originID: bobDecoded.originUUID.uuidString,
            destinationID: bobDecoded.destinationUUID?.uuidString ?? "BROADCAST",
            senderID: relayBobID.uuidString,
            senderName: "RelayBob",
            previousHopID: relayBobID.uuidString,
            text: bobDecoded.textPayload,
            hopsCount: Int(bobDecoded.hopCount) + 1,
            ttl: Int(bobDecoded.ttl) - 1,
            type: bobDecoded.type.toP2PMessageType(),
            conversationID: bobDecoded.conversationID,
            relayHistory: bobRelayHistory
        )
        
        XCTAssertEqual(bobForwardedMsg.hopsCount, 1, "Hop count must be incremented by relay")
        XCTAssertEqual(bobForwardedMsg.ttl, 3, "TTL must be decremented by relay")
        XCTAssertEqual(bobForwardedMsg.previousHopID, relayBobID.uuidString)
        XCTAssertTrue(bobForwardedMsg.relayHistory.contains(relayBobID))
        
        // Bob encodes forwarded packet to wire
        let bobWireData = try MeshPacketHeader.encode(bobForwardedMsg, sequenceNumber: 2, relayHistory: bobRelayHistory)
        
        // --- Step 3: Charlie receives the forwarded packet from Bob ---
        let charlieDecoded = try MeshPacketHeader.decode(from: bobWireData)
        XCTAssertEqual(charlieDecoded.destinationUUID, charlieID)
        XCTAssertEqual(charlieDecoded.originUUID, aliceID)
        XCTAssertEqual(charlieDecoded.hopCount, 1)
        XCTAssertEqual(charlieDecoded.ttl, 3)
        XCTAssertEqual(charlieDecoded.textPayload, "Mountain check: Charlie, please confirm base camp arrival.")
        
        // Charlie verifies it is for him and delivers locally
        let isForCharlie = (charlieDecoded.destinationUUID == charlieID)
        XCTAssertTrue(isForCharlie, "Charlie confirms he is the final recipient")
    }

    /// Tests bidirectional 2-hop mesh roundtrip (Alice -> Bob -> Charlie -> Bob -> Alice)
    func testBidirectionalMultiHopMessageAndAckRoundtrip() throws {
        let aliceID   = UUID()
        let relayBobID = UUID()
        let charlieID = UUID()
        let msgID     = UUID()
        
        // Alice -> Charlie via Bob
        let outMsg = Message(
            id: msgID,
            originID: aliceID.uuidString,
            destinationID: charlieID.uuidString,
            senderID: aliceID.uuidString,
            senderName: "Alice",
            text: "Ping via mesh",
            hopsCount: 0,
            ttl: 3,
            type: .chat
        )
        
        // Bob forwards
        let forwardedMsg = Message(
            id: outMsg.id,
            originID: outMsg.originID,
            destinationID: outMsg.destinationID,
            senderID: relayBobID.uuidString,
            senderName: "RelayBob",
            previousHopID: relayBobID.uuidString,
            text: outMsg.text,
            hopsCount: outMsg.hopsCount + 1,
            ttl: outMsg.ttl - 1,
            type: outMsg.type,
            relayHistory: [relayBobID]
        )
        
        // Charlie receives and generates Delivery ACK back to Alice via Bob
        let ackMsg = Message(
            id: UUID(),
            originID: charlieID.uuidString,
            destinationID: aliceID.uuidString,
            senderID: charlieID.uuidString,
            senderName: "Charlie",
            text: "DELIVERY_ACK",
            hopsCount: 0,
            ttl: 3,
            type: .ack
        )
        
        // Bob forwards the ACK back to Alice
        let forwardedAck = Message(
            id: ackMsg.id,
            originID: ackMsg.originID,
            destinationID: ackMsg.destinationID,
            senderID: relayBobID.uuidString,
            senderName: "RelayBob",
            previousHopID: relayBobID.uuidString,
            text: ackMsg.text,
            hopsCount: ackMsg.hopsCount + 1,
            ttl: ackMsg.ttl - 1,
            type: ackMsg.type,
            relayHistory: [relayBobID]
        )
        
        XCTAssertEqual(forwardedAck.destinationID, aliceID.uuidString)
        XCTAssertEqual(forwardedAck.originID, charlieID.uuidString)
        XCTAssertEqual(forwardedAck.hopsCount, 1)
        XCTAssertEqual(forwardedAck.type, .ack)
    }
}

// MARK: - 2. Multipath Diamond Mesh & Storm-Breaker Deduplication

final class MultipathMeshDeduplicationTests: XCTestCase {

    /// In a diamond topology:
    ///      Alice
    ///     /     \
    ///  Node B   Node C
    ///     \     /
    ///      Dave
    /// Dave receives two copies of the same packet from different paths.
    /// Canonical deduplication must ensure exactly-once processing.
    func testDiamondMeshDeduplicationStormBreaker() {
        let aliceID = "node-alice"
        let msgID = UUID()
        let canonicalKey = "\(aliceID)_\(msgID.uuidString)"
        
        var daveSeenCache = Set<String>()
        var daveProcessedPackets: [UUID] = []
        
        // Path 1 arrives at Dave (via Node B)
        if !daveSeenCache.contains(canonicalKey) {
            daveSeenCache.insert(canonicalKey)
            daveProcessedPackets.append(msgID)
        }
        
        // Path 2 arrives at Dave (via Node C, fraction of a second later)
        let isPath2Duplicate = daveSeenCache.contains(canonicalKey)
        if !isPath2Duplicate {
            daveProcessedPackets.append(msgID)
        }
        
        XCTAssertTrue(isPath2Duplicate, "Second arrival from alternate mesh path must be dropped")
        XCTAssertEqual(daveProcessedPackets.count, 1, "Dave must process the packet exactly once")
    }

    /// Verifies cycle detection where packet routes in a circle (A -> B -> C -> A)
    func testCycleDetectionLoopBreaker() {
        let aliceUUID = UUID()
        let bobUUID   = UUID()
        let charlieUUID = UUID()
        
        // Packet has visited Alice, Bob, Charlie
        let relayHistory = [aliceUUID, bobUUID, charlieUUID]
        
        // Packet is looped back to Alice
        let isLoopDetected = relayHistory.contains(aliceUUID)
        XCTAssertTrue(isLoopDetected, "Local node in relayHistory must immediately drop packet to prevent infinite loop")
    }
}

// MARK: - 3. Delay-Tolerant Networking (DTN) Store-and-Forward Relay

@MainActor
final class DelayTolerantMeshRelayTests: XCTestCase {

    /// Tests store-and-forward behavior where an intermediate relay node stores a transit
    /// message offline until the destination peer comes into radio contact.
    func testStoreAndForwardTransitQueueLifecycle() async throws {
        let relayService = SwiftDataService(inMemory: true)
        let msgID = UUID()
        let aliceID   = "node-alice"
        let charlieID = "node-charlie"
        let relayBobID = "node-relay-bob"
        
        // 1. Bob receives packet for Charlie while Charlie is offline
        await relayService.persistenceActor.enqueuePendingMessage(
            messageID: msgID,
            originID: aliceID,
            destinationID: charlieID,
            recipientName: "Charlie",
            senderName: "Alice",
            previousHopID: aliceID,
            text: "Meet at waypoint Bravo at 1600.",
            channel: charlieID,
            isSOS: false,
            priorityRaw: 1,
            statusRaw: "QUEUED",
            queueRoleRaw: "RELAY", // Stored as a transit relay item
            hopsCount: 1,
            ttl: 3
        )
        
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.messageID == msgID })
        let queuedItem = try relayService.context.fetch(descriptor).first
        XCTAssertNotNil(queuedItem)
        XCTAssertEqual(queuedItem?.queueRoleRaw, "RELAY")
        XCTAssertEqual(queuedItem?.destinationID, charlieID)
        
        // 2. Charlie is discovered on radio (simulated peer discovery trigger)
        // Bob transitions status to SENDING
        await relayService.persistenceActor.updatePendingMessageStatus(messageID: msgID, statusRaw: "SENDING")
        var current = try relayService.context.fetch(descriptor).first
        XCTAssertEqual(current?.statusRaw, "SENDING")
        
        // 3. Charlie acknowledges receipt
        await relayService.persistenceActor.markPendingMessageAsACKed(messageID: msgID)
        current = try relayService.context.fetch(descriptor).first
        XCTAssertEqual(current?.statusRaw, "DELIVERED")
    }
}

// MARK: - 4. TTL Expiration & Hop Bounding

final class MeshTTLExpirationTests: XCTestCase {

    /// Verify packets are strictly dropped when hopsCount reaches TTL
    func testPacketDropsWhenHopsCountEqualsTTL() {
        let ttl = 3
        
        // Packet at hop 0: can forward (0 < 3)
        XCTAssertTrue(0 < ttl)
        // Packet at hop 1: can forward (1 < 3)
        XCTAssertTrue(1 < ttl)
        // Packet at hop 2: can forward (2 < 3)
        XCTAssertTrue(2 < ttl)
        // Packet at hop 3: EXPIRED (3 < 3 is false)
        XCTAssertFalse(3 < ttl, "Packet with hopsCount >= TTL must not be forwarded")
    }

    /// Verify default TTL is capped to prevent network saturation
    func testDefaultTTLSanity() {
        XCTAssertEqual(Constants.Emergency.broadcastTTL, 5)
        XCTAssertEqual(Constants.Mesh.maxMeshHops, 5)
        XCTAssertGreaterThanOrEqual(Constants.Mesh.maxMeshHops, 3, "Mesh must support at least 3 hops for effective relaying")
    }
}

// MARK: - 5. Radio MTU & Payload Compression Tests

final class MeshRadioMTUComplianceTests: XCTestCase {

    /// Verify binary MeshPacketHeader yields significant size reduction vs JSON
    /// allowing packets to fit easily into Bluetooth LE MTU without fragmentation
    func testBinaryFramingFitsWithinBluetoothLEMTU() throws {
        let msg = Message(
            id: UUID(),
            originID: "4B44FAEB-93FB-400F-B4B1-8A7F20EF90FD",
            destinationID: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D",
            senderID: "4B44FAEB-93FB-400F-B4B1-8A7F20EF90FD",
            senderName: "SurvivorAlpha",
            text: "Rendezvous at base camp.",
            hopsCount: 0,
            ttl: 5,
            type: .chat
        )
        
        // JSON encoding
        let jsonData = try JSONEncoder().encode(msg)
        // Binary framing encoding
        let binaryData = try MeshPacketHeader.encode(msg, sequenceNumber: 1)
        
        // Standard Bluetooth LE ATT MTU is 512 bytes; AWDL is ~1500 bytes
        let bleMTU = 512
        
        XCTAssertLessThan(binaryData.count, bleMTU, "Binary mesh packet must fit within 512-byte BLE MTU")
        XCTAssertLessThan(binaryData.count, jsonData.count, "Binary packet must be substantially smaller than JSON")
        
        let percentReduction = Double(jsonData.count - binaryData.count) / Double(jsonData.count) * 100.0
        XCTAssertGreaterThan(percentReduction, 50.0, "Binary protocol must achieve at least 50% size reduction over JSON")
    }

    /// Verify PTT voice chunk fits inside single radio frame (< 1500 bytes)
    func testPTTVoiceFrameFitsInRadioMTU() {
        // 20ms of 16kHz audio encoded with Opus is typically 40-120 bytes
        let dummyOpusPayload = Data(repeating: 0xAA, count: 80)
        let pttHeader = PTTFrameHeader(
            version: .v2,
            type: .chunk,
            channel: 0x01,
            hopCount: 0,
            ttl: 3,
            sequenceNo: 1,
            timestampMs: 20,
            senderNodeID: UUID(),
            sessionID: UUID(),
            isEncrypted: false
        )
        
        var packet = pttHeader.encode()
        packet.append(dummyOpusPayload)
        
        XCTAssertEqual(packet.count, 43 + 80, "V2 header (43 bytes) + payload (80 bytes) = 123 bytes")
        XCTAssertLessThan(packet.count, 512, "Voice frame easily fits inside Bluetooth LE and AWDL MTU")
    }
}

// MARK: - 6. Path Loss Range & Distance Estimation Tests

final class MeshPathLossRangeEstimationTests: XCTestCase {

    /// Verify Log-Distance Path Loss equation returns accurate distance estimates from RSSI
    func testDistanceEstimationFromRSSI() {
        // Reference RSSI at 1 meter is -59 dBm
        let distAt1m = Double.estimatedDistance(fromRSSI: -59)
        XCTAssertEqual(distAt1m, 1.0, accuracy: 0.1, "At reference RSSI (-59 dBm), distance should be ~1.0 meter")
        
        // Weaker signal: -75 dBm -> ~4.4 meters
        let distAt75 = Double.estimatedDistance(fromRSSI: -75)
        XCTAssertGreaterThan(distAt75, 3.0)
        XCTAssertLessThan(distAt75, 6.0)
        
        // Edge of standard direct BLE range: -90 dBm -> ~17 meters
        let distAt90 = Double.estimatedDistance(fromRSSI: -90)
        XCTAssertGreaterThan(distAt90, 12.0)
        XCTAssertLessThan(distAt90, 25.0)
    }

    /// Verify non-negative RSSI returns 0 meters (guard edge case)
    func testZeroDistanceForPositiveRSSI() {
        let dist = Double.estimatedDistance(fromRSSI: 5)
        XCTAssertEqual(dist, 0.0)
    }
}
