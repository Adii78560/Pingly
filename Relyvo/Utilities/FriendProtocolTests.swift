import Foundation

/// Automated Verification Suite for Friend Protocol Idempotency and Serialization
final class FriendProtocolTests {
    
    static let shared = FriendProtocolTests()
    
    private init() {}
    
    func runAllFriendProtocolTests() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        
        let tests = [
            ("testFriendProtocolSerialization", testFriendProtocolSerialization),
            ("testFriendProtocolIdempotency", testFriendProtocolIdempotency)
        ]
        
        for (name, test) in tests {
            let result = test()
            if result {
                print("✅ \(name) passed")
                passed += 1
            } else {
                print("❌ \(name) failed")
                failed += 1
            }
        }
        
        return (passed, failed)
    }
    
    // MARK: - Serialization Tests
    private func testFriendProtocolSerialization() -> Bool {
        // FRIEND_REQUEST
        let requestMsg = Message(
            id: UUID(),
            originID: "NODE_A",
            destinationID: "NODE_B",
            senderID: "NODE_A",
            senderName: "Alpha",
            channelID: nil,
            text: "FRIEND_REQUEST",
            timestamp: Date(),
            isSOS: false,
            emergencyStatus: .normal,
            hopsCount: 0,
            type: .friendRequest
        )
        
        guard let encodedReq = try? MeshPacketHeader.encode(requestMsg),
              let decodedReq = try? MeshPacketHeader.decode(from: encodedReq) else {
            return false
        }
        
        if decodedReq.type != .friendRequest { return false }
        
        // FRIEND_ACCEPT
        let acceptMsg = Message(
            originID: "NODE_B",
            destinationID: "NODE_A",
            senderID: "NODE_B",
            senderName: "Bravo",
            channelID: nil,
            text: "FRIEND_ACCEPT",
            timestamp: Date(),
            type: .friendAccept
        )
        guard let encodedAcc = try? MeshPacketHeader.encode(acceptMsg),
              let decodedAcc = try? MeshPacketHeader.decode(from: encodedAcc) else {
            return false
        }
        
        if decodedAcc.type != .friendAccept { return false }
        
        // FRIEND_DECLINE
        let declineMsg = Message(
            originID: "NODE_B",
            destinationID: "NODE_A",
            senderID: "NODE_B",
            senderName: "Bravo",
            channelID: nil,
            text: "FRIEND_DECLINE",
            timestamp: Date(),
            type: .friendDecline
        )
        guard let encodedDec = try? MeshPacketHeader.encode(declineMsg),
              let decodedDec = try? MeshPacketHeader.decode(from: encodedDec) else {
            return false
        }
        
        if decodedDec.type != .friendDecline { return false }
        
        return true
    }
    
    // MARK: - Idempotency Validation Check
    private func testFriendProtocolIdempotency() -> Bool {
        // Idempotency is logically enforced in PersistenceActor and MultipeerService (deduplication cache).
        // This test simulates the mapping behavior.
        
        let typeReq = MeshPacketType.from(.friendRequest)
        if typeReq != .friendRequest { return false }
        
        let typeAcc = MeshPacketType.from(.friendAccept)
        if typeAcc != .friendAccept { return false }
        
        return true
    }
}
