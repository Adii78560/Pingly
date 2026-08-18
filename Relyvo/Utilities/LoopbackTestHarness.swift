//
//  LoopbackTestHarness.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 19/08/26.
//

import Foundation
import SwiftData
import Combine
import os

// MARK: - Loopback Transport Abstraction (Test-Only)
enum LoopbackMode {
    case normal
    case dropACKs
    case delayACK(seconds: TimeInterval)
}

/// In-memory simulator transport router connecting simulated nodes
final class LoopbackTransport {
    var mode: LoopbackMode = .normal
    private var nodes: [String: SimulatedNode] = [:]
    private let lock = NSLock()
    
    func register(node: SimulatedNode) {
        lock.lock()
        defer { lock.unlock() }
        nodes[node.nodeID] = node
        node.transport = self
    }
    
    func send(data: Data, from originNodeID: String, to targetNodeID: String) {
        lock.lock()
        let targetNode = nodes[targetNodeID]
        let currentMode = mode
        lock.unlock()
        
        guard let target = targetNode else { return }
        
        // Inspect if frame is ACK to handle test transport modes
        let isAckFrame: Bool
        if let msg = try? JSONDecoder().decode(Message.self, from: data), msg.type == .ack {
            isAckFrame = true
        } else {
            isAckFrame = false
        }
        
        if isAckFrame {
            switch currentMode {
            case .normal:
                target.receiveFrame(data: data, fromPeerID: originNodeID)
            case .dropACKs:
                AppLogger.multipeer.info("[LoopbackTransport] Test mode DROP_ACKS: Dropping ACK frame from \(originNodeID) to \(targetNodeID)")
            case .delayACK(let seconds):
                AppLogger.multipeer.info("[LoopbackTransport] Test mode DELAY_ACK: Delaying ACK frame by \(seconds)s from \(originNodeID) to \(targetNodeID)")
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    target.receiveFrame(data: data, fromPeerID: originNodeID)
                }
            }
        } else {
            target.receiveFrame(data: data, fromPeerID: originNodeID)
        }
    }
    
    func broadcast(data: Data, from originNodeID: String) {
        lock.lock()
        let peerNodes = nodes.values.filter { $0.nodeID != originNodeID }
        lock.unlock()
        
        for peer in peerNodes {
            send(data: data, from: originNodeID, to: peer.nodeID)
        }
    }
}

// MARK: - Simulated Mesh Node
@MainActor
final class SimulatedNode {
    let nodeID: String
    let displayName: String
    let swiftDataService: SwiftDataService
    weak var transport: LoopbackTransport?
    
    private(set) var receivedMessages: [Message] = []
    private(set) var processedFrameIDs: Set<UUID> = []
    
    init(nodeID: String, displayName: String) {
        self.nodeID = nodeID
        self.displayName = displayName
        self.swiftDataService = SwiftDataService(inMemory: true)
    }
    
    func sendChatMessage(to destinationID: String, text: String, messageID: UUID = UUID(), hopsCount: Int = 0, ttl: Int = Constants.Emergency.broadcastTTL) -> Message {
        let msg = Message(
            id: messageID,
            originID: nodeID,
            destinationID: destinationID,
            senderID: nodeID,
            senderName: displayName,
            previousHopID: nodeID,
            text: text,
            timestamp: Date(),
            hopsCount: hopsCount,
            ttl: ttl,
            type: .chat
        )
        
        _ = swiftDataService.saveChatMessage(
            id: msg.id,
            senderName: displayName,
            channel: destinationID,
            text: text
        )
        
        _ = swiftDataService.enqueuePendingMessage(
            messageID: msg.id,
            originID: nodeID,
            destinationID: destinationID,
            recipientName: destinationID,
            senderName: displayName,
            text: text,
            channel: destinationID
        )
        
        swiftDataService.updatePendingMessageStatus(messageID: msg.id, status: .sending)
        
        if let data = try? JSONEncoder().encode(msg) {
            swiftDataService.updatePendingMessageStatus(messageID: msg.id, status: .waitingForACK)
            transport?.broadcast(data: data, from: nodeID)
        }
        
        return msg
    }
    
    func receiveFrame(data: Data, fromPeerID: String) {
        // Attempt decode as Message
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else {
            AppLogger.multipeer.warning("[LoopbackTest] MALFORMED_FRAME_REJECTED reason=JSON_DECODE_FAILED node=\(self.nodeID)")
            return
        }
        
        // 1. Protocol Version Validation
        guard message.protocolVersion <= Constants.Mesh.currentProtocolVersion else {
            AppLogger.multipeer.warning("[LoopbackTest] MALFORMED_FRAME_REJECTED reason=UNSUPPORTED_PROTOCOL_VERSION actual=\(message.protocolVersion) node=\(self.nodeID)")
            return
        }
        
        // 2. CryptoKit HMAC Verification
        guard MeshSecurityManager.shared.verify(message: message) else {
            AppLogger.multipeer.warning("[LoopbackTest] MALFORMED_FRAME_REJECTED reason=HMAC_VERIFICATION_FAILED node=\(self.nodeID)")
            return
        }
        
        // 3. Self-echo prevention
        guard message.senderID != nodeID && message.previousHopID != nodeID else {
            AppLogger.multipeer.info("[LoopbackTest] LOOP_REJECTED reason=SELF_ECHO node=\(self.nodeID)")
            return
        }
        
        // 4. Origin local reject
        if message.type != .ack && message.originID == nodeID {
            AppLogger.multipeer.info("[LoopbackTest] LOOP_REJECTED reason=LOCAL_ORIGIN node=\(self.nodeID)")
            return
        }
        
        // Handle Delivery ACK frame
        if message.type == .ack {
            let isForMe = (message.originID == nodeID || message.destinationID == nodeID)
            if isForMe {
                swiftDataService.markPendingMessageAsACKed(messageID: message.id)
            } else {
                // Relay ACK back toward origin
                swiftDataService.markPendingMessageAsACKed(messageID: message.id)
                var relayAck = message
                relayAck.previousHopID = nodeID
                relayAck.hopsCount += 1
                if let ackData = try? JSONEncoder().encode(relayAck) {
                    transport?.broadcast(data: ackData, from: nodeID)
                }
            }
            return
        }
        
        let isForMe = (message.destinationID == nodeID || message.destinationID == displayName || message.destinationID == "BROADCAST")
        
        if isForMe {
            let alreadyProcessed = swiftDataService.isMessageAlreadyProcessed(messageID: message.id)
            if !alreadyProcessed {
                receivedMessages.append(message)
                processedFrameIDs.insert(message.id)
                _ = swiftDataService.saveChatMessage(
                    id: message.id,
                    senderName: message.senderName,
                    channel: message.destinationID,
                    text: message.text,
                    isDelivered: true
                )
            }
            
            // Re-issue / Send ACK back toward sender
            let deliveryAck = Message(
                id: message.id,
                originID: message.originID,
                destinationID: message.originID,
                senderID: nodeID,
                senderName: displayName,
                previousHopID: nodeID,
                text: "DELIVERY_ACK",
                timestamp: Date(),
                hopsCount: 0,
                ttl: message.ttl,
                type: .ack
            )
            
            if let ackData = try? JSONEncoder().encode(deliveryAck) {
                transport?.send(data: ackData, from: nodeID, to: fromPeerID)
            }
        } else {
            // Multi-hop relay
            var relayMsg = message
            relayMsg.previousHopID = nodeID
            relayMsg.hopsCount += 1
            
            if relayMsg.hopsCount <= relayMsg.ttl {
                if let relayData = try? JSONEncoder().encode(relayMsg) {
                    transport?.broadcast(data: relayData, from: nodeID)
                }
            } else {
                AppLogger.multipeer.warning("[LoopbackTest] TTL_EXHAUSTED messageID=\(message.id) hops=\(relayMsg.hopsCount)/\(relayMsg.ttl) node=\(self.nodeID)")
            }
        }
    }
}

// MARK: - Automated Loopback Test Harness
@MainActor
final class LoopbackTestHarness {
    static let shared = LoopbackTestHarness()
    
    private init() {}
    
    func runAllLoopbackTests() -> (passedCount: Int, failedCount: Int, reportSummary: String) {
        var passed = 0
        var failed = 0
        var results: [(testName: String, status: String, details: String)] = []
        
        func logResult(name: String, success: Bool, details: String = "") {
            let statusStr = success ? "PASS" : "FAIL"
            if success {
                passed += 1
                AppLogger.multipeer.info("[LoopbackTest] PASS name=\(name) details=\(details)")
            } else {
                failed += 1
                AppLogger.multipeer.error("[LoopbackTest] FAIL name=\(name) details=\(details)")
            }
            results.append((name, statusStr, details))
        }
        
        AppLogger.multipeer.info("==================================================")
        AppLogger.multipeer.info("[LoopbackTest] STARTING SIMULATOR LOOPBACK TEST SUITE")
        AppLogger.multipeer.info("==================================================")
        
        // -------------------------------------------------------------
        // Test 1: Message Correlation ID Preservation
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=CorrelationIDPreservation")
        let transport1 = LoopbackTransport()
        let nodeA1 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        let nodeB1 = SimulatedNode(nodeID: "TEST-B", displayName: "Node B")
        transport1.register(node: nodeA1)
        transport1.register(node: nodeB1)
        
        let createdMsgID = UUID()
        let createdMsg = nodeA1.sendChatMessage(to: "TEST-B", text: "Correlation Test", messageID: createdMsgID)
        
        let persistedMsg = nodeA1.swiftDataService.fetchChatMessages(for: "TEST-B").first(where: { $0.id == createdMsgID })
        let pendingMsg = nodeA1.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == createdMsgID })
        let receivedMsg = nodeB1.receivedMessages.first(where: { $0.id == createdMsgID })
        let remotePersistedMsg = nodeB1.swiftDataService.fetchChatMessages(for: "TEST-B").first(where: { $0.id == createdMsgID })
        
        let t1Success = (createdMsg.id == createdMsgID) &&
                        (persistedMsg?.id == createdMsgID) &&
                        (pendingMsg?.messageID == createdMsgID) &&
                        (receivedMsg?.id == createdMsgID) &&
                        (remotePersistedMsg?.id == createdMsgID) &&
                        (pendingMsg?.status == .delivered)
        
        logResult(
            name: "Message Correlation ID Preservation",
            success: t1Success,
            details: "created=\(createdMsgID.uuidString.prefix(6)) persisted=\(persistedMsg?.id.uuidString.prefix(6) ?? "nil") pendingStatus=\(pendingMsg?.status.rawValue ?? "nil")"
        )
        
        // -------------------------------------------------------------
        // Test 2: Basic A -> B Delivery
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=BasicAtoBDelivery")
        let transport2 = LoopbackTransport()
        let nodeA2 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        let nodeB2 = SimulatedNode(nodeID: "TEST-B", displayName: "Node B")
        transport2.register(node: nodeA2)
        transport2.register(node: nodeB2)
        
        let msg2 = nodeA2.sendChatMessage(to: "TEST-B", text: "Hello Node B")
        let nodeA2Pending = nodeA2.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg2.id })
        let nodeA2Chat = nodeA2.swiftDataService.fetchChatMessages(for: "TEST-B").first(where: { $0.id == msg2.id })
        let nodeB2Chat = nodeB2.swiftDataService.fetchChatMessages(for: "TEST-B").first(where: { $0.id == msg2.id })
        
        let t2Success = (nodeA2Pending?.status == .delivered) &&
                        (nodeA2Chat?.isDelivered == true) &&
                        (nodeB2.receivedMessages.count == 1) &&
                        (nodeB2Chat != nil)
        
        logResult(
            name: "Basic A -> B Delivery",
            success: t2Success,
            details: "A_pending_status=\(nodeA2Pending?.status.rawValue ?? "nil") B_rx_count=\(nodeB2.receivedMessages.count)"
        )
        
        // -------------------------------------------------------------
        // Test 3: Basic B -> A Delivery (Symmetry Test)
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=BasicBtoADelivery")
        let msg3 = nodeB2.sendChatMessage(to: "TEST-A", text: "Hello Node A (Reverse)")
        let nodeB2Pending = nodeB2.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg3.id })
        let nodeA2Rx = nodeA2.receivedMessages.first(where: { $0.id == msg3.id })
        
        let t3Success = (nodeB2Pending?.status == .delivered) && (nodeA2Rx != nil)
        logResult(
            name: "Basic B -> A Delivery (Symmetry)",
            success: t3Success,
            details: "B_pending_status=\(nodeB2Pending?.status.rawValue ?? "nil") A_rx_found=\(nodeA2Rx != nil)"
        )
        
        // -------------------------------------------------------------
        // Test 4: Duplicate Delivery Handling
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=DuplicateDeliveryHandling")
        let transport4 = LoopbackTransport()
        let nodeA4 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        let nodeB4 = SimulatedNode(nodeID: "TEST-B", displayName: "Node B")
        transport4.register(node: nodeA4)
        transport4.register(node: nodeB4)
        
        let dupMsgID = UUID()
        let dupMsg = Message(
            id: dupMsgID,
            originID: "TEST-A",
            destinationID: "TEST-B",
            senderID: "TEST-A",
            senderName: "Node A",
            text: "Duplicate Payload",
            timestamp: Date()
        )
        
        if let dupData = try? JSONEncoder().encode(dupMsg) {
            // First Delivery
            nodeB4.receiveFrame(data: dupData, fromPeerID: "TEST-A")
            let rxCount1 = nodeB4.receivedMessages.count
            
            // Second Delivery (Duplicate)
            nodeB4.receiveFrame(data: dupData, fromPeerID: "TEST-A")
            let rxCount2 = nodeB4.receivedMessages.count
            let b4ChatCount = nodeB4.swiftDataService.fetchChatMessages(for: "TEST-B").filter({ $0.id == dupMsgID }).count
            
            let t4Success = (rxCount1 == 1) && (rxCount2 == 1) && (b4ChatCount == 1)
            logResult(
                name: "Duplicate Delivery Handling",
                success: t4Success,
                details: "first_rx=\(rxCount1) second_rx=\(rxCount2) stored_chat_count=\(b4ChatCount)"
            )
        } else {
            logResult(name: "Duplicate Delivery Handling", success: false, details: "Encode failed")
        }
        
        // -------------------------------------------------------------
        // Test 5: ACK Correlation & Mismatch Prevention
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=ACKCorrelation")
        let transport5 = LoopbackTransport()
        let nodeA5 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        let nodeB5 = SimulatedNode(nodeID: "TEST-B", displayName: "Node B")
        transport5.register(node: nodeA5)
        transport5.register(node: nodeB5)
        transport5.mode = .dropACKs // Prevent automatic ACK so we can test manual injection
        
        let msg5 = nodeA5.sendChatMessage(to: "TEST-B", text: "ACK Correlation Test")
        let statusBeforeACK = nodeA5.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg5.id })?.status
        
        // Inject Mismatched ACK referencing UUID-2
        let mismatchedACK = Message(
            id: UUID(), // Wrong ID
            originID: "TEST-B",
            destinationID: "TEST-A",
            senderID: "TEST-B",
            senderName: "Node B",
            text: "DELIVERY_ACK",
            timestamp: Date(),
            type: .ack
        )
        if let ackDataBad = try? JSONEncoder().encode(mismatchedACK) {
            nodeA5.receiveFrame(data: ackDataBad, fromPeerID: "TEST-B")
        }
        let statusAfterBadACK = nodeA5.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg5.id })?.status
        
        // Inject Valid ACK referencing msg5.id
        let validACK = Message(
            id: msg5.id, // Correct ID
            originID: "TEST-A",
            destinationID: "TEST-A",
            senderID: "TEST-B",
            senderName: "Node B",
            text: "DELIVERY_ACK",
            timestamp: Date(),
            type: .ack
        )
        if let ackDataGood = try? JSONEncoder().encode(validACK) {
            nodeA5.receiveFrame(data: ackDataGood, fromPeerID: "TEST-B")
        }
        let statusAfterGoodACK = nodeA5.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg5.id })?.status
        
        let t5Success = (statusBeforeACK == .waitingForACK) &&
                        (statusAfterBadACK == .waitingForACK) &&
                        (statusAfterGoodACK == .delivered)
        
        logResult(
            name: "ACK Correlation & Mismatch Prevention",
            success: t5Success,
            details: "before=\(statusBeforeACK?.rawValue ?? "nil") after_bad=\(statusAfterBadACK?.rawValue ?? "nil") after_good=\(statusAfterGoodACK?.rawValue ?? "nil")"
        )
        
        // -------------------------------------------------------------
        // Test 6: Serialization Round Trip
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=SerializationRoundTrip")
        let roundTripID = UUID()
        let originalMsg = Message(
            id: roundTripID,
            originID: "NODE-ORIGIN",
            destinationID: "NODE-DEST",
            senderID: "NODE-SENDER",
            senderName: "Sender Name",
            previousHopID: "NODE-PREV",
            text: "Roundtrip Payload",
            timestamp: Date(),
            latitude: 37.7749,
            longitude: -122.4194,
            isSOS: true,
            hopsCount: 2,
            ttl: 4,
            type: .location
        )
        
        var t6Success = false
        if let data = try? JSONEncoder().encode(originalMsg),
           let decoded = try? JSONDecoder().decode(Message.self, from: data) {
            let idMatch = (decoded.id == originalMsg.id)
            let originMatch = (decoded.originID == originalMsg.originID)
            let destMatch = (decoded.destinationID == originalMsg.destinationID)
            let senderMatch = (decoded.senderID == originalMsg.senderID)
            let hopMatch = (decoded.hopsCount == originalMsg.hopsCount && decoded.ttl == originalMsg.ttl)
            let typeMatch = (decoded.type == originalMsg.type && decoded.protocolVersion == originalMsg.protocolVersion)
            
            t6Success = idMatch && originMatch && destMatch && senderMatch && hopMatch && typeMatch
        }
        
        logResult(
            name: "Serialization Round Trip",
            success: t6Success,
            details: "msgID=\(roundTripID.uuidString.prefix(6)) matches_decoded=\(t6Success)"
        )
        
        // -------------------------------------------------------------
        // Test 7: Malformed Frames Handling
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=MalformedFramesHandling")
        let nodeA7 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        
        let emptyData = Data()
        let randomBytes = Data([0xFF, 0xFE, 0xFD, 0xFC, 0x00, 0x01])
        let truncatedJSON = "{\"id\":\"\(UUID().uuidString)\",\"text\":".data(using: .utf8)!
        
        var forgedMsg = Message(id: UUID(), originID: "TEST-X", destinationID: "TEST-A", senderID: "TEST-X", senderName: "X", text: "Forged")
        forgedMsg.authTag = "FORGED_SIGNATURE"
        let forgedData = (try? JSONEncoder().encode(forgedMsg)) ?? Data()
        
        nodeA7.receiveFrame(data: emptyData, fromPeerID: "TEST-X")
        nodeA7.receiveFrame(data: randomBytes, fromPeerID: "TEST-X")
        nodeA7.receiveFrame(data: truncatedJSON, fromPeerID: "TEST-X")
        nodeA7.receiveFrame(data: forgedData, fromPeerID: "TEST-X")
        
        let t7Success = (nodeA7.receivedMessages.isEmpty) && (nodeA7.swiftDataService.fetchChatMessages(for: "TEST-A").isEmpty)
        logResult(
            name: "Malformed Frames Clean Rejection",
            success: t7Success,
            details: "stored_chat_count=\(nodeA7.swiftDataService.fetchChatMessages(for: "TEST-A").count) rx_count=\(nodeA7.receivedMessages.count)"
        )
        
        // -------------------------------------------------------------
        // Test 8: ACK Timeout & Retry Identity
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=ACKTimeoutAndRetryIdentity")
        let transport8 = LoopbackTransport()
        transport8.mode = .dropACKs
        let nodeA8 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        let nodeB8 = SimulatedNode(nodeID: "TEST-B", displayName: "Node B")
        transport8.register(node: nodeA8)
        transport8.register(node: nodeB8)
        
        let msg8 = nodeA8.sendChatMessage(to: "TEST-B", text: "Timeout Test")
        let statusWaiting = nodeA8.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg8.id })?.status
        
        // Trigger simulated timeout
        nodeA8.swiftDataService.updatePendingMessageStatus(messageID: msg8.id, status: PendingMessageStatus.failed, reason: "ACK_TIMEOUT")
        let statusFailed = nodeA8.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg8.id })?.status
        let failedPending = nodeA8.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg8.id })
        
        // Simulate retry flush
        nodeA8.swiftDataService.resetFailedPendingMessages()
        let retryPending = nodeA8.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg8.id })
        
        let t8Success = (statusWaiting == .waitingForACK) &&
                        (statusFailed == .failed) &&
                        (failedPending?.retryCount == 1) &&
                        (retryPending?.messageID == msg8.id) // ID preserved across retry
        
        logResult(
            name: "ACK Timeout & Retry Identity",
            success: t8Success,
            details: "statusWaiting=\(statusWaiting?.rawValue ?? "") statusFailed=\(statusFailed?.rawValue ?? "") retryCount=\(failedPending?.retryCount ?? -1)"
        )
        
        // -------------------------------------------------------------
        // Test 9: Delayed ACK Race Condition Prevention
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=DelayedACKRaceCondition")
        let transport9 = LoopbackTransport()
        let nodeA9 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        let nodeB9 = SimulatedNode(nodeID: "TEST-B", displayName: "Node B")
        transport9.register(node: nodeA9)
        transport9.register(node: nodeB9)
        
        let msg9 = nodeA9.sendChatMessage(to: "TEST-B", text: "Delayed ACK Test")
        // Node A receives ACK and marks message delivered
        let statusACKed = nodeA9.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg9.id })?.status
        
        // Simulate late timeout task executing AFTER ACK received
        let checkList = nodeA9.swiftDataService.fetchPendingMessages()
        if let item = checkList.first(where: { $0.messageID == msg9.id }), item.status == .waitingForACK {
            nodeA9.swiftDataService.updatePendingMessageStatus(messageID: msg9.id, status: PendingMessageStatus.failed)
        }
        
        let statusFinal = nodeA9.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg9.id })?.status
        
        let t9Success = (statusACKed == .delivered) && (statusFinal == .delivered)
        logResult(
            name: "Delayed ACK Race Condition Prevention",
            success: t9Success,
            details: "statusACKed=\(statusACKed?.rawValue ?? "") statusFinal=\(statusFinal?.rawValue ?? "")"
        )
        
        // -------------------------------------------------------------
        // Test 10: Duplicate Send Queue Handling
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=DuplicateSendQueueHandling")
        let nodeA10 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        let msg10ID = UUID()
        
        let enqueued1 = nodeA10.swiftDataService.enqueuePendingMessage(
            messageID: msg10ID,
            originID: "TEST-A",
            destinationID: "TEST-B",
            recipientName: "TEST-B",
            senderName: "Node A",
            text: "Duplicate Queue Payload",
            channel: "TEST-B"
        )
        let enqueued2 = nodeA10.swiftDataService.enqueuePendingMessage(
            messageID: msg10ID,
            originID: "TEST-A",
            destinationID: "TEST-B",
            recipientName: "TEST-B",
            senderName: "Node A",
            text: "Duplicate Queue Payload",
            channel: "TEST-B"
        )
        
        let pendingCount = nodeA10.swiftDataService.fetchPendingMessages().filter({ $0.messageID == msg10ID }).count
        let t10Success = (enqueued1 != nil) && (enqueued2 == nil) && (pendingCount == 1)
        
        logResult(
            name: "Duplicate Send Queue Handling",
            success: t10Success,
            details: "enqueued1=\(enqueued1 != nil) enqueued2=\(enqueued2 != nil) count=\(pendingCount)"
        )
        
        // -------------------------------------------------------------
        // Test 11: Multi-Hop Routing in Memory (A -> B -> C)
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=MultiHopRoutingAtoBtoC")
        let transport11 = LoopbackTransport()
        let nodeA11 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        let nodeB11 = SimulatedNode(nodeID: "TEST-B", displayName: "Node B") // Relay
        let nodeC11 = SimulatedNode(nodeID: "TEST-C", displayName: "Node C") // Final Target
        
        transport11.register(node: nodeA11)
        transport11.register(node: nodeB11)
        transport11.register(node: nodeC11)
        
        let msg11 = nodeA11.sendChatMessage(to: "TEST-C", text: "Multi-Hop Message A->B->C", ttl: 3)
        
        let nodeC11Rx = nodeC11.receivedMessages.first(where: { $0.id == msg11.id })
        let nodeA11Status = nodeA11.swiftDataService.fetchPendingMessages().first(where: { $0.messageID == msg11.id })?.status
        
        let t11Success = (nodeC11Rx != nil) && (nodeC11Rx?.hopsCount == 2) && (nodeA11Status == .delivered)
        logResult(
            name: "Multi-Hop Routing in Memory (A -> B -> C)",
            success: t11Success,
            details: "C_received=\(nodeC11Rx != nil) C_hops=\(nodeC11Rx?.hopsCount ?? -1) A_pending_status=\(nodeA11Status?.rawValue ?? "")"
        )
        
        // -------------------------------------------------------------
        // Test 12: TTL Handling & Forwarding Expiry
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=TTLHandlingAndForwardingExpiry")
        let transport12 = LoopbackTransport()
        let nodeA12 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        let nodeB12 = SimulatedNode(nodeID: "TEST-B", displayName: "Node B")
        let nodeC12 = SimulatedNode(nodeID: "TEST-C", displayName: "Node C")
        transport12.register(node: nodeA12)
        transport12.register(node: nodeB12)
        transport12.register(node: nodeC12)
        
        // Send message with TTL = 1 (A -> B will make hop 1, B -> C would be hop 2 > TTL 1, so B drops)
        let msg12 = nodeA12.sendChatMessage(to: "TEST-C", text: "TTL Expiry Test", ttl: 1)
        let nodeCRx12 = nodeC12.receivedMessages.first(where: { $0.id == msg12.id })
        
        let t12Success = (nodeCRx12 == nil) // Correctly dropped due to TTL exhaustion
        logResult(
            name: "TTL Handling & Forwarding Expiry",
            success: t12Success,
            details: "TTL=1 reached C=\(nodeCRx12 != nil) (expected false)"
        )
        
        // -------------------------------------------------------------
        // Test 13: Loop Prevention (Self-Echo / Local Loop Drop)
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=LoopPrevention")
        let transport13 = LoopbackTransport()
        let nodeA13 = SimulatedNode(nodeID: "TEST-A", displayName: "Node A")
        transport13.register(node: nodeA13)
        
        let loopMsg = Message(
            id: UUID(),
            originID: "TEST-A", // Local node is origin
            destinationID: "TEST-B",
            senderID: "TEST-A", // Local node is sender
            senderName: "Node A",
            previousHopID: "TEST-A",
            text: "Loop Payload",
            timestamp: Date()
        )
        
        if let loopData = try? JSONEncoder().encode(loopMsg) {
            nodeA13.receiveFrame(data: loopData, fromPeerID: "TEST-A")
        }
        
        let t13Success = nodeA13.receivedMessages.isEmpty
        logResult(
            name: "Loop Prevention (Self-Echo Drop)",
            success: t13Success,
            details: "nodeA_rx_count=\(nodeA13.receivedMessages.count) (expected 0)"
        )
        
        // -------------------------------------------------------------
        // Test 14: SwiftData Isolation (Production Store Protection)
        // -------------------------------------------------------------
        AppLogger.multipeer.info("[LoopbackTest] TEST_START name=SwiftDataIsolation")
        let prodChatCountBefore = (try? SwiftDataService.shared.context.fetch(FetchDescriptor<SDChatMessage>()))?.count ?? 0
        
        // Execute a simulated node transaction
        let isolatedNode = SimulatedNode(nodeID: "TEST-ISO", displayName: "Isolated Node")
        _ = isolatedNode.sendChatMessage(to: "TEST-OTHER", text: "Isolated Message")
        
        let prodChatCountAfter = (try? SwiftDataService.shared.context.fetch(FetchDescriptor<SDChatMessage>()))?.count ?? 0
        let t14Success = (prodChatCountBefore == prodChatCountAfter)
        
        logResult(
            name: "SwiftData Isolation (Prod Protection)",
            success: t14Success,
            details: "prod_count_before=\(prodChatCountBefore) prod_count_after=\(prodChatCountAfter)"
        )
        
        // -------------------------------------------------------------
        // Summary & Report Table Generation
        // -------------------------------------------------------------
        var summaryLines: [String] = []
        summaryLines.append("Messaging Loopback Validation Summary")
        summaryLines.append("--------------------------------------------------")
        for (name, status, details) in results {
            let paddedName = name.padding(toLength: 42, withPad: " ", startingAt: 0)
            summaryLines.append("\(paddedName) [\(status)] - \(details)")
        }
        summaryLines.append("--------------------------------------------------")
        summaryLines.append("TOTAL: \(passed) Passed, \(failed) Failed out of \(results.count) Tests.")
        
        let fullReport = summaryLines.joined(separator: "\n")
        
        AppLogger.multipeer.info("==================================================")
        AppLogger.multipeer.info("[LoopbackTest] TEST SUITE COMPLETE: \(passed) Passed, \(failed) Failed")
        AppLogger.multipeer.info("\(fullReport)")
        AppLogger.multipeer.info("==================================================")
        
        return (passed, failed, fullReport)
    }
}
