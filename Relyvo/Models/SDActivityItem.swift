import Foundation
import SwiftData

@Model
public final class SDActivityItem {
    @Attribute(.unique) public var id: UUID
    public var timestamp: Date
    public var peerID: String
    public var displayName: String
    public var typeRaw: String
    public var statusRaw: String
    public var isRead: Bool
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        peerID: String,
        displayName: String,
        typeRaw: String,
        statusRaw: String = "PENDING",
        isRead: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.peerID = peerID
        self.displayName = displayName
        self.typeRaw = typeRaw
        self.statusRaw = statusRaw
        self.isRead = isRead
    }
}
