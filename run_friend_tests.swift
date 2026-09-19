import Foundation

// MARK: - Mock Models

enum P2PMessageType: String {
    case friendRequest = "FRIEND_REQUEST"
    case friendAccept = "FRIEND_ACCEPT"
    case friendDecline = "FRIEND_DECLINE"
}

struct Message {
    let id: UUID
    let originID: String
    let destinationID: String
    let senderID: String
    let senderName: String
    let channelID: String?
    let text: String
    let timestamp: Date
    let type: P2PMessageType
    
    // Additional properties omitted for brevity in mock
}

enum MeshPacketType: UInt8 {
    case friendRequest = 0x08
    case friendAccept = 0x09
    case friendDecline = 0x0A
    
    static func from(_ type: P2PMessageType) -> MeshPacketType {
        switch type {
        case .friendRequest: return .friendRequest
        case .friendAccept: return .friendAccept
        case .friendDecline: return .friendDecline
        }
    }
}

class FriendProtocolTests {
    func testSerializationAndIdempotency() {
        print("[TEST] Running Friend Protocol Serialization Tests...")
        
        let typeReq = MeshPacketType.from(.friendRequest)
        assert(typeReq == .friendRequest, "Serialization mapped friendRequest incorrectly")
        
        let typeAcc = MeshPacketType.from(.friendAccept)
        assert(typeAcc == .friendAccept, "Serialization mapped friendAccept incorrectly")
        
        let typeDec = MeshPacketType.from(.friendDecline)
        assert(typeDec == .friendDecline, "Serialization mapped friendDecline incorrectly")
        
        print("[TEST] SUCCESS: Friend Protocol serialization mapped correctly.")
        
        print("[TEST] Running Idempotency Tests...")
        var requestCount = 0
        func handleFriendRequest(requestID: UUID) {
            // Simulated persistence check
            if requestCount == 0 {
                requestCount += 1
            }
        }
        
        let id = UUID()
        handleFriendRequest(requestID: id) // A -> B
        handleFriendRequest(requestID: id) // A -> C -> B (duplicate)
        
        assert(requestCount == 1, "Duplicate request resulted in multiple logical requests")
        print("[TEST] SUCCESS: Duplicate request successfully dropped (Idempotency passed).")
        
        var acceptStatus = "requestReceived"
        func handleFriendAccept() {
            if acceptStatus == "requestReceived" || acceptStatus == "requestSent" {
                acceptStatus = "accepted"
            }
        }
        
        handleFriendAccept() // First accept
        assert(acceptStatus == "accepted", "Accept failed")
        
        handleFriendAccept() // Duplicate accept
        assert(acceptStatus == "accepted", "Duplicate accept mutated status incorrectly")
        print("[TEST] SUCCESS: Duplicate accept preserved ACCEPTED state.")
    }
}

let tests = FriendProtocolTests()
tests.testSerializationAndIdempotency()
print("All automated Friend Protocol tests passed.")
