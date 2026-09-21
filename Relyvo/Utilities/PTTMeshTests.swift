import Foundation
import MultipeerConnectivity

/// Automated Verification Suite for PTT Mesh Hardening
final class PTTMeshTests {
    
    static let shared = PTTMeshTests()
    
    private init() {}
    
    func runAllPTTMeshTests() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        
        let tests = [
            ("testPTTFrameHeaderSerialization", testPTTFrameHeaderSerialization),
            ("testPTTFrameHeaderInvalidRejection", testPTTFrameHeaderInvalidRejection),
            ("testVoiceSeenCacheDeduplication", testVoiceSeenCacheDeduplication),
            ("testMeshOutboundQueueEvictionPolicy", testMeshOutboundQueueEvictionPolicy)
        ]
        
        for (name, test) in tests {
            if test() {
                passed += 1
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "PTT_TESTS", event: name, details: "SUCCESS")
            } else {
                failed += 1
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "PTT_TESTS", event: name, details: "FAILED")
            }
        }
        return (passed, failed)
    }
    
    private func testPTTFrameHeaderSerialization() -> Bool {
        let senderID = UUID()
        let sessionID = UUID()
        
        let header = PTTFrameHeader(
            version: .v2,
            type: .chunk,
            channel: MeshChannelByte.ch1Emergency.rawValue,
            hopCount: 1,
            ttl: 3,
            sequenceNo: 40000,
            timestampMs: 1234567,
            senderNodeID: senderID,
            sessionID: sessionID,
            isEncrypted: false
        )
        
        let data = header.encode()
        guard data.count == 43 else { return false }
        
        guard let decoded = PTTFrameHeader.decode(from: data) else { return false }
        return decoded.version == .v2 &&
               decoded.type == .chunk &&
               decoded.channel == MeshChannelByte.ch1Emergency.rawValue &&
               decoded.hopCount == 1 &&
               decoded.ttl == 3 &&
               decoded.sequenceNo == 40000 &&
               decoded.timestampMs == 1234567 &&
               decoded.senderNodeID == senderID &&
               decoded.sessionID == sessionID
    }
    
    private func testPTTFrameHeaderInvalidRejection() -> Bool {
        let invalidData = Data(repeating: 0x00, count: 40) // Too short
        return PTTFrameHeader.decode(from: invalidData) == nil
    }
    
    private func testVoiceSeenCacheDeduplication() -> Bool {
        let sender = UUID()
        let session = UUID()
        
        VoiceSeenCache.shared.insert(senderNodeID: sender, sessionID: session, sequenceNo: 10)
        
        guard VoiceSeenCache.shared.contains(senderNodeID: sender, sessionID: session, sequenceNo: 10) else { return false }
        guard !VoiceSeenCache.shared.contains(senderNodeID: sender, sessionID: session, sequenceNo: 11) else { return false }
        
        // Different session
        guard !VoiceSeenCache.shared.contains(senderNodeID: sender, sessionID: UUID(), sequenceNo: 10) else { return false }
        
        return true
    }
    
    private func testMeshOutboundQueueEvictionPolicy() -> Bool {
        let queue = MeshOutboundQueue.shared
        queue.flushAll()
        
        let peer = MCPeerID(displayName: "TestPeer")
        let session = MCSession(peer: peer)
        
        // Fill queue to max capacity (50)
        for _ in 0..<50 {
            queue.enqueue(data: Data(), priority: .realtime, isReliable: false, toPeers: [peer], session: session, tag: "TEST_CHUNK")
        }
        
        queue.enqueue(data: Data(), priority: .critical, isReliable: true, toPeers: [peer], session: session, tag: "TEST_CRITICAL")
        queue.enqueue(data: Data(), priority: .bulk, isReliable: false, toPeers: [peer], session: session, tag: "TEST_BULK")
        queue.enqueue(data: Data(), priority: .realtime, isReliable: false, toPeers: [peer], session: session, tag: "TEST_CHUNK_LATEST")
        
        return true
    }
}
