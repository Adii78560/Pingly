//
//  StoreAndForwardTests.swift
//  Relyvo
//

import XCTest
@testable import Relyvo

final class StoreAndForwardTests: XCTestCase {
    
    func testDeterministicConversationID() {
        let nodeA = UUID().uuidString
        let nodeB = UUID().uuidString
        
        let conv1 = DirectConversationID.make(nodeA: nodeA, nodeB: nodeB)
        let conv2 = DirectConversationID.make(nodeA: nodeB, nodeB: nodeA)
        
        XCTAssertEqual(conv1, conv2, "Deterministic conversation ID must be order-independent")
        
        let conv3 = DirectConversationID.make(nodeA: nodeA, nodeB: UUID().uuidString)
        XCTAssertNotEqual(conv1, conv3, "Different peers should yield different conversation IDs")
    }
    
    func testHeaderV3Roundtrip() throws {
        let originID = UUID().uuidString
        let destID = UUID().uuidString
        
        let message = Message(
            originID: originID,
            destinationID: destID,
            senderID: originID,
            senderName: "Alice",
            channelID: nil,
            text: "Hello Store & Forward",
            hopsCount: 1,
            ttl: 3,
            type: .chat,
            protocolVersion: 3,
            conversationID: DirectConversationID.make(nodeA: originID, nodeB: destID),
            relayHistory: [UUID(), UUID()]
        )
        
        let encoded = MeshPacketHeader.encode(message, sequenceNumber: 0, isEOT: false, relayHistory: message.relayHistory)
        XCTAssertEqual(encoded[2], 0x03, "Protocol version should be 3")
        
        let decoded = try MeshPacketHeader.decode(from: encoded)
        
        XCTAssertEqual(decoded.version, 0x03)
        XCTAssertEqual(decoded.conversationID, message.conversationID)
        XCTAssertEqual(decoded.relayHistory.count, 2)
        XCTAssertEqual(decoded.textPayload, "Hello Store & Forward")
        
        let reconstructedMessage = decoded.toMessage(senderDisplayName: "Alice")
        XCTAssertEqual(reconstructedMessage.conversationID, message.conversationID)
        XCTAssertEqual(reconstructedMessage.relayHistory.count, 2)
    }
    
    func testLoopPrevention() {
        let localNodeID = UUID().uuidString
        let localUUID = UUID(uuidString: localNodeID)!
        let originID = UUID().uuidString
        let messageID = UUID()
        
        let msg = Message(
            id: messageID,
            originID: originID,
            destinationID: UUID().uuidString,
            senderID: originID,
            senderName: "Alice",
            text: "Loop test",
            relayHistory: [localUUID]
        )
        
        let containsLocal = msg.relayHistory.contains(localUUID)
        XCTAssertTrue(containsLocal, "Message should contain local UUID in relay history")
    }
}
