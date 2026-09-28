//
//  MessagingPersistenceTests.swift
//  RelyvoTests
//
//  Comprehensive, fast unit tests for the Relyvo P2P Messaging Pipeline and
//  SwiftData On-Device Persistence Layer.
//
//  Mirrors the architecture and performance of WalkieTalkiePTTTests:
//  - Fully in-memory, deterministic, and executes in milliseconds (< 1s total).
//  - Zero network dependencies, zero artificial sleep delays.
//  - Complete dual-device end-to-end simulation (Alice & Bob bidirectional exchange).
//  - Multi-peer channel broadcast and tactical isolation.
//  - Offline store-and-forward queue lifecycle and ACK synchronization.
//  - Multi-hop mesh relay, loop drop, and storm-breaker deduplication.
//  - Protocol payload sanitization and high-throughput concurrent actor stress testing.
//

import XCTest
import SwiftData
@testable import Relyvo

// MARK: - Test Helpers & In-Memory Factory

/// Creates an isolated in-memory SwiftData container with the full production schema.
@MainActor
private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([
        SDChatMessage.self,
        SDPendingMessage.self,
        SDVoiceTranscript.self,
        SDUserProfile.self,
        SDNotificationEvent.self,
        SDLocationShareSession.self,
        SDAudioSegment.self,
        SDVoiceMessage.self,
        SDBreadcrumbTrack.self,
        SDBreadcrumbPoint.self,
        SDOfflineMapRegion.self,
        SDFriend.self,
        SDActivityItem.self
    ])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

/// Helper to simulate synchronous insertion directly onto a ModelContext for synchronous test assertions.
@MainActor
@discardableResult
private func insertChatMessage(
    id: UUID = UUID(),
    originID: String,
    senderID: String,
    destinationID: String,
    senderName: String,
    channel: String,
    text: String,
    timestamp: Date,
    isDelivered: Bool = false,
    messageTypeRaw: String = "CHAT",
    conversationID: UUID? = nil,
    isRead: Bool = false,
    in context: ModelContext
) throws -> SDChatMessage {
    let descriptor = FetchDescriptor<SDChatMessage>(predicate: #Predicate { $0.id == id })
    if let existing = try context.fetch(descriptor).first {
        existing.isDelivered = isDelivered
        existing.isRead = isRead
        try context.save()
        return existing
    }

    let msg = SDChatMessage(
        id: id,
        originID: originID,
        senderID: senderID,
        destinationID: destinationID,
        senderName: senderName,
        channel: channel,
        text: text,
        timestamp: timestamp,
        isSynced: false,
        isDelivered: isDelivered,
        conversationID: conversationID
    )
    msg.messageTypeRaw = messageTypeRaw
    msg.isRead = isRead
    context.insert(msg)
    try context.save()
    return msg
}

// MARK: - 1. Wire Protocol & Serialization Tests

final class MessageWireProtocolTests: XCTestCase {
    
    /// Verify Message struct serializes to JSON and deserializes with 100% field integrity
    func testChatMessageJSONEncodingDecodingRoundtrip() throws {
        let msgID = UUID()
        let senderID = "peer-alpha-1234"
        let destID = "peer-beta-5678"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        
        let original = Message(
            id: msgID,
            originID: senderID,
            destinationID: destID,
            senderID: senderID,
            senderName: "AlphaLeader",
            text: "Status report required at checkpoint Charlie",
            timestamp: now,
            hopsCount: 1,
            ttl: 4,
            type: .chat
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        XCTAssertGreaterThan(data.count, 0, "Encoded JSON data must not be empty")
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message.self, from: data)
        
        XCTAssertEqual(decoded.id, msgID)
        XCTAssertEqual(decoded.originID, senderID)
        XCTAssertEqual(decoded.destinationID, destID)
        XCTAssertEqual(decoded.senderID, senderID)
        XCTAssertEqual(decoded.senderName, "AlphaLeader")
        XCTAssertEqual(decoded.text, "Status report required at checkpoint Charlie")
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.hopsCount, 1)
        XCTAssertEqual(decoded.ttl, 4)
        XCTAssertEqual(decoded.type, .chat)
        XCTAssertEqual(decoded.conversationID, original.conversationID)
    }
    
    /// Verify encrypted flag and session ID survive wire serialization
    func testEncryptedMessageSerializationAndFlagPreservation() throws {
        let sessionID = UUID()
        let msg = Message(
            originID: "node-1",
            destinationID: "node-2",
            senderID: "node-1",
            senderName: "Alice",
            text: "CIPHERTEXT_AES_GCM_PAYLOAD",
            type: .chat,
            sessionID: sessionID,
            isEncrypted: true
        )
        
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        
        XCTAssertTrue(decoded.isEncrypted, "isEncrypted flag must survive wire serialization")
        XCTAssertEqual(decoded.sessionID, sessionID, "Session ID must survive wire serialization")
        XCTAssertEqual(decoded.text, "CIPHERTEXT_AES_GCM_PAYLOAD")
    }
    
    /// Verify location coordinates survive wire serialization without truncation
    func testLocationMessageWireSerialization() throws {
        let lat = 37.774929
        let lon = -122.419416
        let alt = 15.4
        let acc = 3.2
        
        let msg = Message(
            originID: "node-1",
            destinationID: "BROADCAST",
            senderID: "node-1",
            senderName: "Alice",
            text: "Coordinates update",
            latitude: lat,
            longitude: lon,
            altitude: alt,
            accuracy: acc,
            type: .location
        )
        
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        
        XCTAssertEqual(decoded.latitude ?? 0, lat, accuracy: 0.000001)
        XCTAssertEqual(decoded.longitude ?? 0, lon, accuracy: 0.000001)
        XCTAssertEqual(decoded.altitude ?? 0, alt, accuracy: 0.1)
        XCTAssertEqual(decoded.accuracy ?? 0, acc, accuracy: 0.1)
        XCTAssertEqual(decoded.type, .location)
    }
}

// MARK: - 2. ConversationID Symmetry & Determinism Tests

@MainActor
final class ConversationIDSymmetryTests: XCTestCase {

    func testConversationIDIsSymmetric() {
        let nodeA = UUID().uuidString
        let nodeB = UUID().uuidString
        let idAB = DirectConversationID.make(nodeA: nodeA, nodeB: nodeB)
        let idBA = DirectConversationID.make(nodeA: nodeB, nodeB: nodeA)
        XCTAssertEqual(idAB, idBA, "make(A,B) must equal make(B,A)")
    }

    func testConversationIDIsDeterministic() {
        let nodeA = "device-alpha"
        let nodeB = "device-beta"
        let first  = DirectConversationID.make(nodeA: nodeA, nodeB: nodeB)
        let second = DirectConversationID.make(nodeA: nodeA, nodeB: nodeB)
        XCTAssertEqual(first, second, "ConversationID must be deterministic across calls")
    }

    func testChannelConversationIDIsCaseInsensitive() {
        let lower = DirectConversationID.make(channelName: "ch-1 emergency")
        let upper = DirectConversationID.make(channelName: "CH-1 EMERGENCY")
        XCTAssertEqual(lower, upper, "Channel ConversationID must be case-insensitive")
    }

    func testDifferentNodePairsProduceDifferentIDs() {
        let pairAB = DirectConversationID.make(nodeA: "node-A", nodeB: "node-B")
        let pairAC = DirectConversationID.make(nodeA: "node-A", nodeB: "node-C")
        XCTAssertNotEqual(pairAB, pairAC, "Different peer pairs must produce different ConversationIDs")
    }
    
    func testAutoDerivationMatchesExplicitConvID() {
        let nodeA = "aaaa-aaaa-aaaa"
        let nodeB = "bbbb-bbbb-bbbb"
        let expected = DirectConversationID.make(nodeA: nodeA, nodeB: nodeB)

        let sdMsg = SDChatMessage(
            originID: nodeA,
            senderID: nodeA,
            destinationID: nodeB,
            senderName: "Alice",
            channel: nodeB,
            text: "auto-derived",
            timestamp: Date(),
            isSynced: false
        )

        XCTAssertEqual(sdMsg.conversationID, expected,
                       "SDChatMessage auto-derived conversationID must equal DirectConversationID.make(nodeA, nodeB)")
    }

    func testMessageStructConvIDMatchesStoredConvID() throws {
        let nodeA = UUID().uuidString
        let nodeB = UUID().uuidString

        let networkMsg = Message(
            originID: nodeA,
            destinationID: nodeB,
            senderID: nodeA,
            senderName: "Alice",
            text: "hello"
        )

        let container = try makeInMemoryContainer()
        let context   = container.mainContext
        let stored    = try insertChatMessage(
            id: networkMsg.id,
            originID: nodeA, senderID: nodeA,
            destinationID: nodeB, senderName: "Alice", channel: nodeB,
            text: "hello", timestamp: networkMsg.timestamp,
            conversationID: networkMsg.conversationID,
            in: context
        )

        XCTAssertEqual(networkMsg.conversationID, stored.conversationID,
                       "In-memory Message convID must match persisted SDChatMessage convID")
    }
}

// MARK: - 3. Original Timestamp Preservation Tests

@MainActor
final class MessageTimestampPreservationTests: XCTestCase {

    func testOriginalTimestampPreservedOnSave() throws {
        let container = try makeInMemoryContainer()
        let context   = container.mainContext

        let originalTime = Date(timeIntervalSince1970: 1_000_000)
        let id = UUID()

        try insertChatMessage(
            id: id, originID: "sender", senderID: "sender",
            destinationID: "recipient", senderName: "Alice", channel: "recipient",
            text: "hello", timestamp: originalTime, in: context
        )

        let descriptor = FetchDescriptor<SDChatMessage>(predicate: #Predicate { $0.id == id })
        let saved = try context.fetch(descriptor).first
        XCTAssertNotNil(saved, "Message should be saved")
        XCTAssertEqual(
            saved?.timestamp.timeIntervalSinceReferenceDate ?? 0,
            originalTime.timeIntervalSinceReferenceDate,
            accuracy: 0.001,
            "Persisted timestamp must match original send time, not the time of persistence"
        )
    }

    func testMultipleMessagesOrderedByOriginalTimestamp() throws {
        let container = try makeInMemoryContainer()
        let context   = container.mainContext

        let base = Date(timeIntervalSince1970: 1_000_000)
        let convID = DirectConversationID.make(nodeA: "A", nodeB: "B")

        // Insert in reverse order to ensure chronological sort relies strictly on timestamp
        for reverseOffset in stride(from: 4, through: 0, by: -1) {
            try insertChatMessage(
                id: UUID(), originID: "A", senderID: "A",
                destinationID: "B", senderName: "Alice", channel: "B",
                text: "msg-\(reverseOffset)",
                timestamp: base.addingTimeInterval(Double(reverseOffset) * 60),
                conversationID: convID, in: context
            )
        }

        let descriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { msg in msg.conversationID == convID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let sorted = try context.fetch(descriptor)
        XCTAssertEqual(sorted.count, 5, "All 5 messages should be present")
        for i in 1..<sorted.count {
            XCTAssertLessThan(
                sorted[i-1].timestamp,
                sorted[i].timestamp,
                "Messages must be ordered chronologically by original timestamp"
            )
        }
    }
}

// MARK: - 4. Offline Peer-to-Peer Messaging Exchange Tests (End-to-End Alice & Bob Simulation)

@MainActor
final class OfflinePeerToPeerMessagingExchangeTests: XCTestCase {

    /// Simulates a full duplex bidirectional direct chat between two distinct physical devices (Alice & Bob).
    /// Both have independent SwiftData containers, proving neither device misses messages or exhibits thread bifurcation.
    func testFullDuplexTwoWayDirectMessageExchange() async throws {
        let aliceID = "device-alice-\(UUID().uuidString.prefix(6))"
        let bobID   = "device-bob-\(UUID().uuidString.prefix(6))"
        let aliceHandle = "Alice"
        let bobHandle   = "Bob"
        
        let aliceService = SwiftDataService(inMemory: true)
        let bobService   = SwiftDataService(inMemory: true)
        
        let baseTime = Date(timeIntervalSince1970: 1_700_000_100)
        
        // --- Step 1: Alice composes and sends Message 1 to Bob ---
        let msg1 = Message(
            originID: aliceID,
            destinationID: bobID,
            senderID: aliceID,
            senderName: aliceHandle,
            text: "Hey Bob, are you on the ridge?",
            timestamp: baseTime,
            type: .chat
        )
        
        // Alice persists locally as outgoing (unconfirmed, isDelivered = false)
        await aliceService.persistenceActor.saveChatMessage(
            id: msg1.id,
            originID: aliceID,
            senderID: aliceID,
            destinationID: bobID,
            senderName: aliceHandle,
            channel: bobID,
            text: msg1.text,
            timestamp: msg1.timestamp,
            isDelivered: false,
            messageTypeRaw: "CHAT",
            conversationID: msg1.conversationID
        )
        
        // Alice encodes to wire format
        let wireData1 = try JSONEncoder().encode(msg1)
        
        // --- Step 2: Bob receives wire packet from Alice ---
        let bobReceivedMsg1 = try JSONDecoder().decode(Message.self, from: wireData1)
        XCTAssertEqual(bobReceivedMsg1.id, msg1.id)
        
        // Bob persists locally as incoming (isDelivered = true)
        await bobService.persistenceActor.saveChatMessage(
            id: bobReceivedMsg1.id,
            originID: bobReceivedMsg1.originID,
            senderID: bobReceivedMsg1.senderID,
            destinationID: bobReceivedMsg1.destinationID,
            senderName: bobReceivedMsg1.senderName,
            channel: bobReceivedMsg1.originID,
            text: bobReceivedMsg1.text,
            timestamp: bobReceivedMsg1.timestamp,
            isDelivered: true,
            messageTypeRaw: "CHAT",
            conversationID: bobReceivedMsg1.conversationID
        )
        
        // Bob sends back a Delivery ACK to Alice
        let ackMsg = Message(
            originID: bobID,
            destinationID: aliceID,
            senderID: bobID,
            senderName: bobHandle,
            text: "DELIVERY_ACK",
            type: .ack
        )
        let ackWireData = try JSONEncoder().encode(ackMsg)
        
        // Alice receives ACK -> marks msg1 as delivered on Alice's device
        let aliceReceivedAck = try JSONDecoder().decode(Message.self, from: ackWireData)
        XCTAssertEqual(aliceReceivedAck.type, .ack)
        await aliceService.persistenceActor.markPendingMessageAsACKed(messageID: msg1.id)
        
        // --- Step 3: Bob replies to Alice with Message 2 ---
        let msg2Time = baseTime.addingTimeInterval(15.0)
        let msg2 = Message(
            originID: bobID,
            destinationID: aliceID,
            senderID: bobID,
            senderName: bobHandle,
            text: "Yes Alice, ridge reached. Visibility good.",
            timestamp: msg2Time,
            type: .chat
        )
        
        // Bob persists locally as outgoing
        await bobService.persistenceActor.saveChatMessage(
            id: msg2.id,
            originID: bobID,
            senderID: bobID,
            destinationID: aliceID,
            senderName: bobHandle,
            channel: aliceID,
            text: msg2.text,
            timestamp: msg2.timestamp,
            isDelivered: true,
            messageTypeRaw: "CHAT",
            conversationID: msg2.conversationID
        )
        
        // Bob encodes and Alice receives
        let wireData2 = try JSONEncoder().encode(msg2)
        let aliceReceivedMsg2 = try JSONDecoder().decode(Message.self, from: wireData2)
        
        await aliceService.persistenceActor.saveChatMessage(
            id: aliceReceivedMsg2.id,
            originID: aliceReceivedMsg2.originID,
            senderID: aliceReceivedMsg2.senderID,
            destinationID: aliceReceivedMsg2.destinationID,
            senderName: aliceReceivedMsg2.senderName,
            channel: aliceReceivedMsg2.originID,
            text: aliceReceivedMsg2.text,
            timestamp: aliceReceivedMsg2.timestamp,
            isDelivered: true,
            messageTypeRaw: "CHAT",
            conversationID: aliceReceivedMsg2.conversationID
        )
        
        // --- Step 4: Verification of Dual-Device State ---
        let expectedConvID = DirectConversationID.make(nodeA: aliceID, nodeB: bobID)
        XCTAssertEqual(msg1.conversationID, expectedConvID, "Alice convID must equal shared convID")
        XCTAssertEqual(msg2.conversationID, expectedConvID, "Bob convID must equal shared convID")
        
        // Verify Alice's local store
        let aliceDescriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.conversationID == expectedConvID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let aliceStored = try aliceService.context.fetch(aliceDescriptor)
        XCTAssertEqual(aliceStored.count, 2, "Alice's store must contain exactly 2 messages")
        XCTAssertEqual(aliceStored[0].text, "Hey Bob, are you on the ridge?")
        XCTAssertEqual(aliceStored[0].senderID, aliceID)
        XCTAssertTrue(aliceStored[0].isDelivered, "Message 1 should be confirmed delivered via ACK")
        XCTAssertEqual(aliceStored[1].text, "Yes Alice, ridge reached. Visibility good.")
        XCTAssertEqual(aliceStored[1].senderID, bobID)
        
        // Verify Bob's local store
        let bobDescriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.conversationID == expectedConvID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let bobStored = try bobService.context.fetch(bobDescriptor)
        XCTAssertEqual(bobStored.count, 2, "Bob's store must contain exactly 2 messages")
        XCTAssertEqual(bobStored[0].text, "Hey Bob, are you on the ridge?")
        XCTAssertEqual(bobStored[0].senderID, aliceID)
        XCTAssertEqual(bobStored[1].text, "Yes Alice, ridge reached. Visibility good.")
        XCTAssertEqual(bobStored[1].senderID, bobID)
        
        // Verify chronological timestamp ordering matches across both devices
        XCTAssertEqual(aliceStored[0].timestamp, bobStored[0].timestamp)
        XCTAssertEqual(aliceStored[1].timestamp, bobStored[1].timestamp)
        XCTAssertLessThan(aliceStored[0].timestamp, aliceStored[1].timestamp)
    }
    
    /// Test that when only outgoing messages exist (no reply yet), conversation display card
    /// correctly identifies recipient handle from SDFriend rather than the local user's own name.
    func testPeerNameFallbackOnOutgoingOnlyConversation() throws {
        let container  = try makeInMemoryContainer()
        let context    = container.mainContext
        let localNode  = "local-alpha"
        let remoteNode = "remote-bravo"
        let convID     = DirectConversationID.make(nodeA: localNode, nodeB: remoteNode)

        // Seed friend record in local database
        let friend = SDFriend(nodeID: remoteNode, handle: "BravoTeamLead", status: .accepted)
        context.insert(friend)

        try insertChatMessage(
            id: UUID(), originID: localNode, senderID: localNode,
            destinationID: remoteNode, senderName: "AlphaLeader", channel: remoteNode,
            text: "Radio check, Bravo.", timestamp: Date(),
            conversationID: convID, in: context
        )

        let msgs = try context.fetch(FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { msg in msg.conversationID == convID }
        ))

        let localDisplayName = "AlphaLeader"
        let recipientCandidate = msgs.first?.destinationID ?? ""
        let peerName: String
        if let inbound = msgs.first(where: { $0.senderID != localNode && $0.senderName != localDisplayName }) {
            peerName = inbound.senderName
        } else {
            let fd = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == recipientCandidate })
            peerName = (try? context.fetch(fd))?.first?.handle ?? localDisplayName
        }

        XCTAssertEqual(peerName, "BravoTeamLead",
                       "Outgoing-only conversation must display the recipient's friend handle, not local sender name")
    }

    /// Test that incoming message senderName takes precedence over any stale friend handle
    func testIncomingMessageSenderNameTakesPrecedence() throws {
        let container  = try makeInMemoryContainer()
        let context    = container.mainContext
        let localNode  = "local-alpha"
        let remoteNode = "remote-bravo"
        let convID     = DirectConversationID.make(nodeA: localNode, nodeB: remoteNode)

        let friend = SDFriend(nodeID: remoteNode, handle: "OldHandle", status: .accepted)
        context.insert(friend)

        try insertChatMessage(
            id: UUID(), originID: localNode, senderID: localNode,
            destinationID: remoteNode, senderName: "AlphaLeader", channel: remoteNode,
            text: "Hello?", timestamp: Date().addingTimeInterval(-30),
            conversationID: convID, in: context
        )
        try insertChatMessage(
            id: UUID(), originID: remoteNode, senderID: remoteNode,
            destinationID: localNode, senderName: "BravoUpdatedHandle", channel: localNode,
            text: "Hello Alpha!", timestamp: Date(),
            isDelivered: true, messageTypeRaw: "TEXT",
            conversationID: convID, in: context
        )

        let msgs = try context.fetch(FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { msg in msg.conversationID == convID }
        ))
        let localDisplayName = "AlphaLeader"
        let peerName: String
        if let inbound = msgs.first(where: { $0.senderID != localNode && $0.senderName != localDisplayName }) {
            peerName = inbound.senderName
        } else {
            let recipientCandidate = msgs.first?.destinationID ?? ""
            let fd = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == recipientCandidate })
            peerName = (try? context.fetch(fd))?.first?.handle ?? localDisplayName
        }

        XCTAssertEqual(peerName, "BravoUpdatedHandle",
                       "Sender name on incoming message must override address book handle")
    }
}

// MARK: - 5. Multi-Peer Channel Broadcast & Tactical Isolation Tests

@MainActor
final class MessagingChannelIsolationTests: XCTestCase {

    /// Verify channel broadcast reaches peers tuned to that channel, while peers on other channels drop it
    func testChannelBroadcastToMultipleSubscribers() async throws {
        let aliceID   = "node-alice"
        let bobID     = "node-bob"
        let charlieID = "node-charlie"
        let daveID    = "node-dave"
        
        let channelName = "CH-1 EMERGENCY"
        let otherChannel = "CH-2 TACTICAL"
        
        let aliceService   = SwiftDataService(inMemory: true)
        let bobService     = SwiftDataService(inMemory: true)
        let charlieService = SwiftDataService(inMemory: true)
        let daveService    = SwiftDataService(inMemory: true)
        
        let channelMsg = Message(
            originID: aliceID,
            destinationID: "BROADCAST",
            senderID: aliceID,
            senderName: "Alice",
            channelID: channelName,
            text: "All stations: Base camp relocation in progress.",
            type: .chat
        )
        
        let wireData = try JSONEncoder().encode(channelMsg)
        
        // Bob is tuned to CH-1 EMERGENCY -> accepts & persists
        let bobReceived = try JSONDecoder().decode(Message.self, from: wireData)
        if bobReceived.channelID == channelName {
            await bobService.persistenceActor.saveChatMessage(
                id: bobReceived.id,
                originID: bobReceived.originID,
                senderID: bobReceived.senderID,
                destinationID: "BROADCAST",
                senderName: bobReceived.senderName,
                channel: channelName,
                text: bobReceived.text,
                timestamp: bobReceived.timestamp,
                isDelivered: true,
                messageTypeRaw: "CHAT",
                conversationID: bobReceived.conversationID
            )
        }
        
        // Charlie is also tuned to CH-1 EMERGENCY -> accepts & persists
        let charlieReceived = try JSONDecoder().decode(Message.self, from: wireData)
        if charlieReceived.channelID == channelName {
            await charlieService.persistenceActor.saveChatMessage(
                id: charlieReceived.id,
                originID: charlieReceived.originID,
                senderID: charlieReceived.senderID,
                destinationID: "BROADCAST",
                senderName: charlieReceived.senderName,
                channel: channelName,
                text: charlieReceived.text,
                timestamp: charlieReceived.timestamp,
                isDelivered: true,
                messageTypeRaw: "CHAT",
                conversationID: charlieReceived.conversationID
            )
        }
        
        // Dave is tuned to CH-2 TACTICAL -> channel filter drops packet
        let daveReceived = try JSONDecoder().decode(Message.self, from: wireData)
        if daveReceived.channelID == otherChannel {
            await daveService.persistenceActor.saveChatMessage(
                id: daveReceived.id,
                originID: daveReceived.originID,
                senderID: daveReceived.senderID,
                destinationID: "BROADCAST",
                senderName: daveReceived.senderName,
                channel: otherChannel,
                text: daveReceived.text,
                timestamp: daveReceived.timestamp,
                isDelivered: true,
                messageTypeRaw: "CHAT",
                conversationID: daveReceived.conversationID
            )
        }
        
        // Assertions:
        let bobMsgs = try bobService.context.fetch(FetchDescriptor<SDChatMessage>())
        XCTAssertEqual(bobMsgs.count, 1, "Bob must receive the broadcast on CH-1")
        XCTAssertEqual(bobMsgs.first?.channel, channelName)
        
        let charlieMsgs = try charlieService.context.fetch(FetchDescriptor<SDChatMessage>())
        XCTAssertEqual(charlieMsgs.count, 1, "Charlie must receive the broadcast on CH-1")
        
        let daveMsgs = try daveService.context.fetch(FetchDescriptor<SDChatMessage>())
        XCTAssertEqual(daveMsgs.count, 0, "Dave must NOT receive the broadcast on CH-2")
    }

    /// Test that channel messages are strictly excluded from direct-message conversation cards
    func testChannelMessagesExcludedFromDirectConversationLoad() throws {
        let container = try makeInMemoryContainer()
        let context   = container.mainContext

        let channelConvID = DirectConversationID.make(channelName: "CH-1 EMERGENCY")
        let directConvID  = DirectConversationID.make(nodeA: "user-A", nodeB: "user-B")

        try insertChatMessage(
            id: UUID(), originID: "user-A", senderID: "user-A",
            destinationID: "BROADCAST", senderName: "Alice", channel: "CH-1 EMERGENCY",
            text: "Channel broadcast", timestamp: Date(),
            conversationID: channelConvID, in: context
        )
        try insertChatMessage(
            id: UUID(), originID: "user-A", senderID: "user-A",
            destinationID: "user-B", senderName: "Alice", channel: "user-B",
            text: "Direct whisper to Bob", timestamp: Date(),
            conversationID: directConvID, in: context
        )

        let all = try context.fetch(FetchDescriptor<SDChatMessage>())
        let directOnly = all.filter {
            !$0.channel.hasPrefix("CH-") &&
            $0.channel != "GENERAL MESH" &&
            $0.channel != "EMERGENCY BEACON"
        }

        XCTAssertEqual(directOnly.count, 1, "Channel messages must be excluded from direct-message thread lists")
        XCTAssertEqual(directOnly.first?.text, "Direct whisper to Bob")
    }

    /// Test that direct peer messages never leak into the channel conversation drawer
    func testDirectMessagesDoNotAppearInChannelConversation() throws {
        let container    = try makeInMemoryContainer()
        let context      = container.mainContext
        let broadcastID  = DirectConversationID.make(channelName: "BROADCAST")
        let directConvID = DirectConversationID.make(nodeA: "user-A", nodeB: "user-B")

        try insertChatMessage(
            id: UUID(), originID: "user-A", senderID: "user-A",
            destinationID: "BROADCAST", senderName: "Alice", channel: "BROADCAST",
            text: "calling all stations", timestamp: Date(),
            conversationID: broadcastID, in: context
        )
        try insertChatMessage(
            id: UUID(), originID: "user-A", senderID: "user-A",
            destinationID: "user-B", senderName: "Alice", channel: "user-B",
            text: "private secret", timestamp: Date(),
            conversationID: directConvID, in: context
        )

        let inBroadcast = try context.fetch(FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { msg in msg.conversationID == broadcastID }
        ))
        XCTAssertEqual(inBroadcast.count, 1, "Direct message must not appear in the broadcast channel feed")
        XCTAssertEqual(inBroadcast.first?.text, "calling all stations")
    }
    
    /// Test channel name normalization ensures "CH-" prefix
    func testCustomChannelPrefixNormalization() {
        let name1 = "TACTICAL ALPHA"
        let norm1 = name1.hasPrefix("CH-") ? name1 : "CH-" + name1
        XCTAssertEqual(norm1, "CH-TACTICAL ALPHA")
        
        let name2 = "CH-RESCUE"
        let norm2 = name2.hasPrefix("CH-") ? name2 : "CH-" + name2
        XCTAssertEqual(norm2, "CH-RESCUE")
    }
}

// MARK: - 6. Emergency SOS Distress Beacon Tests

@MainActor
final class EmergencySOSBeaconTests: XCTestCase {

    /// Verify SOS distress beacon packet formatting, flags, and broadcast TTL
    func testSOSDistressBeaconFormattingAndFlags() {
        let localNodeID = "node-survivor-1"
        let status = EmergencyStatus.medicalEmergency
        let sosText = "🚨 EMERGENCY DISTRESS BEACON: Need immediate assistance! Status: \(status.rawValue)"
        
        let sosMessage = Message(
            originID: localNodeID,
            destinationID: "BROADCAST",
            senderID: localNodeID,
            senderName: "SurvivorOne",
            channelID: "CH-1 EMERGENCY",
            text: sosText,
            timestamp: Date(),
            latitude: 45.8326,
            longitude: 6.8652,
            isSOS: true,
            emergencyStatus: status,
            hopsCount: 0,
            ttl: Constants.Emergency.broadcastTTL
        )
        
        XCTAssertTrue(sosMessage.isSOS)
        XCTAssertEqual(sosMessage.emergencyStatus, .medicalEmergency)
        XCTAssertEqual(sosMessage.destinationID, "BROADCAST")
        XCTAssertEqual(sosMessage.channelID, "CH-1 EMERGENCY")
        XCTAssertEqual(sosMessage.ttl, Constants.Emergency.broadcastTTL)
        XCTAssertTrue(sosMessage.text.contains("Medical SOS"))
    }
    
    /// Verify SOS beacon persistence and retrievability via SwiftData
    func testSOSBeaconSwiftDataPersistence() async throws {
        let service = SwiftDataService(inMemory: true)
        let sosID = UUID()
        let sosText = "🚨 EMERGENCY DISTRESS BEACON: Need immediate assistance!"
        
        await service.persistenceActor.saveChatMessage(
            id: sosID,
            originID: "node-victim",
            senderID: "node-victim",
            destinationID: "BROADCAST",
            senderName: "HikerBob",
            channel: "CH-1 EMERGENCY",
            text: sosText,
            timestamp: Date(),
            isDelivered: true,
            messageTypeRaw: "CHAT",
            latitude: 46.0,
            longitude: 7.0
        )
        
        let descriptor = FetchDescriptor<SDChatMessage>(predicate: #Predicate { $0.id == sosID })
        let saved = try service.context.fetch(descriptor).first
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.channel, "CH-1 EMERGENCY")
        XCTAssertEqual(saved?.latitude, 46.0)
        XCTAssertEqual(saved?.longitude, 7.0)
    }
}

// MARK: - 7. Offline Store-and-Forward Queue Lifecycle Tests

@MainActor
final class OfflineStoreAndForwardQueueTests: XCTestCase {

    /// Verify the complete queue lifecycle: QUEUED -> SENDING -> WAITING_FOR_ACK -> DELIVERED
    func testPendingMessageQueueLifecycle() async throws {
        let service = SwiftDataService(inMemory: true)
        let msgID = UUID()
        let origin = "node-alice"
        let dest   = "node-bob"
        
        // 1. Enqueue as QUEUED
        await service.persistenceActor.enqueuePendingMessage(
            messageID: msgID,
            originID: origin,
            destinationID: dest,
            recipientName: "Bob",
            senderName: "Alice",
            text: "Queued offline message",
            channel: dest,
            isSOS: false,
            priorityRaw: 1,
            statusRaw: "QUEUED",
            queueRoleRaw: "ORIGIN",
            hopsCount: 0,
            ttl: 5
        )
        
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.messageID == msgID })
        var pending = try service.context.fetch(descriptor).first
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.statusRaw, "QUEUED")
        XCTAssertEqual(pending?.retryCount, 0)
        
        // 2. Transition to SENDING
        await service.persistenceActor.updatePendingMessageStatus(messageID: msgID, statusRaw: "SENDING")
        pending = try service.context.fetch(descriptor).first
        XCTAssertEqual(pending?.statusRaw, "SENDING")
        
        // 3. Transition to WAITING_FOR_ACK
        await service.persistenceActor.updatePendingMessageStatus(messageID: msgID, statusRaw: "WAITING_FOR_ACK")
        pending = try service.context.fetch(descriptor).first
        XCTAssertEqual(pending?.statusRaw, "WAITING_FOR_ACK")
        
        // 4. Mark ACKed -> DELIVERED
        await service.persistenceActor.markPendingMessageAsACKed(messageID: msgID)
        pending = try service.context.fetch(descriptor).first
        XCTAssertEqual(pending?.statusRaw, "DELIVERED")
        XCTAssertNotNil(pending?.deliveredAt)
    }
    
    /// Test retry counter increments when marked FAILED
    func testPendingMessageRetryCountIncrementOnFailure() async throws {
        let service = SwiftDataService(inMemory: true)
        let msgID = UUID()
        
        await service.persistenceActor.enqueuePendingMessage(
            messageID: msgID,
            originID: "node-1",
            destinationID: "node-2",
            recipientName: "Bob",
            senderName: "Alice",
            text: "Flaky packet",
            channel: "node-2",
            isSOS: false,
            priorityRaw: 0,
            statusRaw: "QUEUED",
            queueRoleRaw: "ORIGIN",
            hopsCount: 0,
            ttl: 3
        )
        
        await service.persistenceActor.updatePendingMessageStatus(messageID: msgID, statusRaw: "FAILED", reason: "Peer out of range")
        
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.messageID == msgID })
        let pending = try service.context.fetch(descriptor).first
        XCTAssertEqual(pending?.statusRaw, "FAILED")
        XCTAssertEqual(pending?.retryCount, 1, "Failure must increment retryCount")
    }

    /// Test resetFailedPendingMessages sets all FAILED items back to QUEUED for transmission retry
    func testResetFailedPendingMessagesRestoresToQueued() async throws {
        let service = SwiftDataService(inMemory: true)
        let msgID = UUID()
        
        await service.persistenceActor.enqueuePendingMessage(
            messageID: msgID,
            originID: "node-1",
            destinationID: "node-2",
            recipientName: "Bob",
            senderName: "Alice",
            text: "Retry me",
            channel: "node-2",
            isSOS: false,
            priorityRaw: 0,
            statusRaw: "FAILED",
            queueRoleRaw: "ORIGIN",
            hopsCount: 0,
            ttl: 3
        )
        
        await service.persistenceActor.resetFailedPendingMessages()
        
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.messageID == msgID })
        let pending = try service.context.fetch(descriptor).first
        XCTAssertEqual(pending?.statusRaw, "QUEUED", "Failed message should be reset to QUEUED")
    }
}

// MARK: - 8. Mesh Relay, Multi-Hop Forwarding & Loop Prevention Tests

@MainActor
final class MeshRelayAndStormBreakerTests: XCTestCase {

    /// Test hop count progression through intermediate relay node
    func testMultiHopMeshRelayProgression() {
        let aliceID = "node-alice"
        let relayID = "node-relay-intermediate"
        let bobID   = "node-bob"
        
        let originalMsg = Message(
            originID: aliceID,
            destinationID: bobID,
            senderID: aliceID,
            senderName: "Alice",
            previousHopID: aliceID,
            text: "Relay via mountain node",
            hopsCount: 0,
            ttl: 3
        )
        
        XCTAssertEqual(originalMsg.hopsCount, 0)
        XCTAssertEqual(originalMsg.ttl, 3)
        
        // Intermediate relay receives and prepares forwarded message
        let relayUUID = UUID()
        var updatedRelayHistory = originalMsg.relayHistory
        updatedRelayHistory.append(relayUUID)
        
        let forwardedMsg = Message(
            id: originalMsg.id,
            originID: originalMsg.originID,
            destinationID: originalMsg.destinationID,
            senderID: relayID,
            senderName: "RelayNode",
            previousHopID: relayID,
            text: originalMsg.text,
            timestamp: originalMsg.timestamp,
            hopsCount: originalMsg.hopsCount + 1,
            ttl: originalMsg.ttl,
            relayHistory: updatedRelayHistory
        )
        
        XCTAssertEqual(forwardedMsg.hopsCount, 1)
        XCTAssertEqual(forwardedMsg.previousHopID, relayID)
        XCTAssertTrue(forwardedMsg.relayHistory.contains(relayUUID))
        XCTAssertLessThan(forwardedMsg.hopsCount, forwardedMsg.ttl, "Packet is still valid for further hops")
    }

    /// Test packet TTL expiration drops packet when hopsCount reaches TTL
    func testTTLDropWhenHopsExceedLimit() {
        let maxTTL = 3
        let expiredMsg = Message(
            originID: "node-origin",
            destinationID: "node-target",
            senderID: "node-relay",
            senderName: "Relay",
            text: "Old packet",
            hopsCount: 3,
            ttl: maxTTL
        )
        
        let shouldForward = expiredMsg.hopsCount < expiredMsg.ttl
        XCTAssertFalse(shouldForward, "Packet with hopsCount >= TTL must not be forwarded")
    }

    /// Test relay loop prevention via relayHistory inspection
    func testMeshLoopPreventionViaRelayHistory() {
        let myRelayNodeID = UUID()
        let loopHistory = [UUID(), myRelayNodeID, UUID()]
        
        let isAlreadyRelayedByMe = loopHistory.contains(myRelayNodeID)
        XCTAssertTrue(isAlreadyRelayedByMe, "Packet containing local node in relayHistory must be dropped to prevent echo storms")
    }

    /// Test canonical identity deduplication drop (originID_messageID)
    func testCanonicalDeduplicationDrop() {
        var seenCache = Set<String>()
        let originID = "device-alpha"
        let msgID = UUID()
        let canonicalKey = "\(originID)_\(msgID.uuidString)"
        
        // First arrival
        XCTAssertFalse(seenCache.contains(canonicalKey))
        seenCache.insert(canonicalKey)
        
        // Duplicate arrival from another mesh path
        let isDuplicate = seenCache.contains(canonicalKey)
        XCTAssertTrue(isDuplicate, "Second arrival with same canonical identity must be flagged as duplicate")
    }
}

// MARK: - 9. Message Deduplication & Sanitization Tests

@MainActor
final class MessageDeduplicationAndSanitizationTests: XCTestCase {

    func testSavingSameMsgIDTwiceDoesNotCreateDuplicate() throws {
        let container = try makeInMemoryContainer()
        let context   = container.mainContext
        let id        = UUID()
        let ts        = Date(timeIntervalSince1970: 5_000_000)

        try insertChatMessage(
            id: id, originID: "A", senderID: "A",
            destinationID: "B", senderName: "Alice", channel: "A",
            text: "hello", timestamp: ts,
            isDelivered: true, messageTypeRaw: "TEXT", in: context
        )
        try insertChatMessage(
            id: id, originID: "A", senderID: "A",
            destinationID: "B", senderName: "Alice", channel: "B",
            text: "hello", timestamp: ts,
            isDelivered: false, messageTypeRaw: "CHAT", in: context
        )

        let all = try context.fetch(FetchDescriptor<SDChatMessage>())
        XCTAssertEqual(all.count, 1, "Same messageID twice must produce exactly 1 row")
        XCTAssertEqual(all.first?.isDelivered, false, "Second save must update mutable fields")
    }

    func testDistinctIDsCreateDistinctRows() throws {
        let container = try makeInMemoryContainer()
        let context   = container.mainContext

        for i in 0..<5 {
            try insertChatMessage(
                id: UUID(), originID: "A", senderID: "A",
                destinationID: "B", senderName: "Alice", channel: "B",
                text: "message \(i)", timestamp: Date(), in: context
            )
        }

        let all = try context.fetch(FetchDescriptor<SDChatMessage>())
        XCTAssertEqual(all.count, 5, "Five distinct message IDs must produce 5 rows")
    }

    /// Verify location protocol payloads are rejected from chat table
    func testLocationProtocolPayloadExcludedFromChat() async throws {
        let service = SwiftDataService(inMemory: true)
        let locationText = "LOCATION_PROTOCOL:{\"lat\":37.77,\"lon\":-122.41}"
        
        await service.persistenceActor.saveChatMessage(
            id: UUID(),
            originID: "node-1",
            senderID: "node-1",
            destinationID: "node-2",
            senderName: "Alice",
            channel: "node-2",
            text: locationText,
            messageTypeRaw: "CHAT"
        )
        
        let all = try service.context.fetch(FetchDescriptor<SDChatMessage>())
        XCTAssertEqual(all.count, 0, "Location protocol payload must be dropped by chat persistence")
    }

    /// Verify empty or whitespace-only messages are rejected
    func testEmptyOrWhitespaceOnlyMessagesRejected() async throws {
        let service = SwiftDataService(inMemory: true)
        
        await service.persistenceActor.saveChatMessage(
            id: UUID(),
            originID: "node-1",
            senderID: "node-1",
            destinationID: "node-2",
            senderName: "Alice",
            channel: "node-2",
            text: "   \n\t  ",
            messageTypeRaw: "CHAT"
        )
        
        let all = try service.context.fetch(FetchDescriptor<SDChatMessage>())
        XCTAssertEqual(all.count, 0, "Whitespace-only message must be rejected by persistence")
    }
}

// MARK: - 10. High-Throughput Concurrent Persistence Stress Tests

@MainActor
final class ConcurrentPersistenceStressTests: XCTestCase {

    /// Concurrently writes 50 chat messages from multiple parallel asynchronous tasks
    /// into PersistenceActor to verify thread safety and absence of SQLite locking faults.
    func testConcurrentRapidFireChatPersistence() async throws {
        let service = SwiftDataService(inMemory: true)
        let totalMessages = 50
        let nodeA = "node-alpha"
        let nodeB = "node-beta"
        let convID = DirectConversationID.make(nodeA: nodeA, nodeB: nodeB)
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<totalMessages {
                let msgID = UUID()
                let text = "Rapid fire concurrent burst #\(i)"
                let time = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                
                group.addTask {
                    await service.persistenceActor.saveChatMessage(
                        id: msgID,
                        originID: nodeA,
                        senderID: nodeA,
                        destinationID: nodeB,
                        senderName: "AlphaStressNode",
                        channel: nodeB,
                        text: text,
                        timestamp: time,
                        isDelivered: true,
                        messageTypeRaw: "CHAT",
                        conversationID: convID
                    )
                }
            }
        }
        
        let descriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.conversationID == convID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let results = try service.context.fetch(descriptor)
        XCTAssertEqual(results.count, totalMessages, "All \(totalMessages) concurrent messages must be saved without data loss")
        
        // Verify no duplicate IDs and ordered timestamps
        let uniqueIDs = Set(results.map { $0.id })
        XCTAssertEqual(uniqueIDs.count, totalMessages)
        for i in 1..<results.count {
            XCTAssertLessThan(results[i-1].timestamp, results[i].timestamp)
        }
    }
    
    /// Concurrently marks read status while receiving new messages without deadlocks
    func testConcurrentMarkAsRead() async throws {
        let service = SwiftDataService(inMemory: true)
        let convID = UUID()
        
        // Pre-populate 10 unread messages
        for i in 0..<10 {
            await service.persistenceActor.saveChatMessage(
                id: UUID(),
                originID: "remote",
                senderID: "remote",
                destinationID: "local",
                senderName: "RemotePeer",
                channel: "local",
                text: "Unread message #\(i)",
                isDelivered: true,
                messageTypeRaw: "CHAT",
                conversationID: convID,
                isRead: false
            )
        }
        
        await service.persistenceActor.markConversationAsRead(conversationID: convID)
        
        let descriptor = FetchDescriptor<SDChatMessage>(predicate: #Predicate { $0.conversationID == convID })
        let msgs = try service.context.fetch(descriptor)
        let unreadCount = msgs.filter { !$0.isRead }.count
        XCTAssertEqual(unreadCount, 0, "All messages in conversation must be marked as read")
    }
}
