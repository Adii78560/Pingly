import Foundation

public struct LocationSessionState: Sendable, Identifiable, Equatable {
    public var id: String { remotePeerID }
    public let remotePeerID: String
    public var remoteDisplayName: String
    public var isSharingLocal: Bool
    public var isSharingRemote: Bool
    public var isActive: Bool
    public var lastLocalLatitude: Double?
    public var lastLocalLongitude: Double?
    public var lastLocalAccuracy: Double?
    public var lastLocalTimestamp: Date?
    public var lastRemoteLatitude: Double?
    public var lastRemoteLongitude: Double?
    public var lastRemoteAccuracy: Double?
    public var lastRemoteSpeed: Double?
    public var lastRemoteCourse: Double?
    public var lastRemoteTimestamp: Date?
    public var sequenceNumber: Int
    public var lastRemoteSequenceNumber: Int?
    public var stateRaw: String
    
    public init(
        remotePeerID: String,
        remoteDisplayName: String,
        isSharingLocal: Bool = false,
        isSharingRemote: Bool = false,
        isActive: Bool = true,
        lastLocalLatitude: Double? = nil,
        lastLocalLongitude: Double? = nil,
        lastLocalAccuracy: Double? = nil,
        lastLocalTimestamp: Date? = nil,
        lastRemoteLatitude: Double? = nil,
        lastRemoteLongitude: Double? = nil,
        lastRemoteAccuracy: Double? = nil,
        lastRemoteSpeed: Double? = nil,
        lastRemoteCourse: Double? = nil,
        lastRemoteTimestamp: Date? = nil,
        sequenceNumber: Int = 0,
        lastRemoteSequenceNumber: Int? = nil,
        stateRaw: String = "ACTIVE"
    ) {
        self.remotePeerID = remotePeerID
        self.remoteDisplayName = remoteDisplayName
        self.isSharingLocal = isSharingLocal
        self.isSharingRemote = isSharingRemote
        self.isActive = isActive
        self.lastLocalLatitude = lastLocalLatitude
        self.lastLocalLongitude = lastLocalLongitude
        self.lastLocalAccuracy = lastLocalAccuracy
        self.lastLocalTimestamp = lastLocalTimestamp
        self.lastRemoteLatitude = lastRemoteLatitude
        self.lastRemoteLongitude = lastRemoteLongitude
        self.lastRemoteAccuracy = lastRemoteAccuracy
        self.lastRemoteSpeed = lastRemoteSpeed
        self.lastRemoteCourse = lastRemoteCourse
        self.lastRemoteTimestamp = lastRemoteTimestamp
        self.sequenceNumber = sequenceNumber
        self.lastRemoteSequenceNumber = lastRemoteSequenceNumber
        self.stateRaw = stateRaw
    }
}
