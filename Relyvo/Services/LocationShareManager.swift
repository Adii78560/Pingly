//
//  LocationShareManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 14/08/26.
//

import Foundation
import CoreLocation
import Combine
import SwiftUI
import os

/// Codable payload models for offline mesh location protocol packets
struct LocationPacket: Codable {
    let type: String // "LOCATION_REQUEST", "LOCATION_RESPONSE", "LOCATION_UPDATE", "LOCATION_SHARING_STOPPED", "RELATIVE_POSITION", "LOCATION_EXPIRED"
    let id: UUID
    let senderID: String
    let senderName: String
    let recipientID: String
    let timestamp: Date
    let accepted: Bool?
    let latitude: Double?
    let longitude: Double?
    let accuracy: Double?
    let speed: Double?
    let course: Double?
    let sequenceNumber: Int?
    let distanceMeters: Double?
    let relativeBearing: Double?
    let compassDirection: String?
}

/// Central Manager coordinating offline P2P location sharing sessions, coordinate broadcasts, and battery optimization
final class LocationShareManager: ObservableObject {
    
    static let shared = LocationShareManager()
    
    @Published public private(set) var activeSessions: [String: SDLocationShareSession] = [:]
    @Published public var pendingIncomingRequests: [String: String] = [:] // peerID -> senderName
    
    private var broadcastTimer: Timer?
    private var expirationTimer: Timer?
    private let lock = NSLock()
    private var localSequenceNumber: Int = 0
    
    private init() {
        reloadActiveSessions()
        startPeriodicBroadcastTimer()
        startExpirationTimer()
    }
    
    // MARK: - Session Management
    
    public func reloadActiveSessions() {
        let sessions = SwiftDataService.shared.fetchAllLocationShareSessions()
        var dict: [String: SDLocationShareSession] = [:]
        for s in sessions {
            dict[s.remotePeerID] = s
        }
        DispatchQueue.main.async {
            self.activeSessions = dict
        }
    }
    
    public func getSession(for remotePeerID: String) -> SDLocationShareSession? {
        return SwiftDataService.shared.fetchLocationShareSession(remotePeerID: remotePeerID)
    }
    
    // MARK: - User Actions
    
    /// 1. Ask for Location: Transmits LOCATION_REQUEST packet to remote peer and creates chat event
    public func requestLocation(from remotePeerID: String, displayName: String) {
        let localNodeID = NodeIdentity.shared.nodeID
        let localName = NodeIdentity.shared.displayName
        
        let packet = LocationPacket(
            type: "LOCATION_REQUEST",
            id: UUID(),
            senderID: localNodeID,
            senderName: localName,
            recipientID: remotePeerID,
            timestamp: Date(),
            accepted: nil,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            speed: nil,
            course: nil,
            sequenceNumber: nil,
            distanceMeters: nil,
            relativeBearing: nil,
            compassDirection: nil
        )
        
        sendLocationPacket(packet, destinationID: remotePeerID)
        SwiftDataService.shared.updateLocationShareSession(
            remotePeerID: remotePeerID,
            remoteDisplayName: displayName,
            stateRaw: "REQUEST_PENDING"
        )
        reloadActiveSessions()
        
        saveChatLocationEvent(
            type: .locationRequest,
            text: "Requested location from \(displayName)",
            destinationID: remotePeerID,
            senderID: localNodeID,
            senderName: localName
        )
        
        AppLogger.location.info("[LocationRequest] Transmitted LOCATION_REQUEST to '\(displayName)' (\(remotePeerID))")
    }
    
    /// 2. Respond to Location Request (Accept/Deny)
    public func respondToLocationRequest(from remotePeerID: String, displayName: String, accept: Bool) {
        let localNodeID = NodeIdentity.shared.nodeID
        let localName = NodeIdentity.shared.displayName
        
        let packet = LocationPacket(
            type: "LOCATION_RESPONSE",
            id: UUID(),
            senderID: localNodeID,
            senderName: localName,
            recipientID: remotePeerID,
            timestamp: Date(),
            accepted: accept,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            speed: nil,
            course: nil,
            sequenceNumber: nil,
            distanceMeters: nil,
            relativeBearing: nil,
            compassDirection: nil
        )
        
        sendLocationPacket(packet, destinationID: remotePeerID)
        
        DispatchQueue.main.async {
            self.pendingIncomingRequests.removeValue(forKey: remotePeerID)
        }
        
        if accept {
            startSharingLocation(with: remotePeerID, displayName: displayName)
            saveChatLocationEvent(
                type: .locationResponse,
                text: "Accepted location request from \(displayName)",
                destinationID: remotePeerID,
                senderID: localNodeID,
                senderName: localName
            )
        } else {
            SwiftDataService.shared.updateLocationShareSession(
                remotePeerID: remotePeerID,
                remoteDisplayName: displayName,
                isSharingLocal: false,
                stateRaw: "DENIED"
            )
            reloadActiveSessions()
            saveChatLocationEvent(
                type: .locationResponse,
                text: "Declined location request from \(displayName)",
                destinationID: remotePeerID,
                senderID: localNodeID,
                senderName: localName
            )
        }
        AppLogger.location.info("[LocationResponse] Transmitted LOCATION_RESPONSE accept=\(accept) to '\(displayName)'")
    }
    
    /// 3. Share My Location: Enables continuous location sharing for local user with target peer
    public func startSharingLocation(with remotePeerID: String, displayName: String) {
        let localNodeID = NodeIdentity.shared.nodeID
        let localName = NodeIdentity.shared.displayName
        
        LocationService.shared.startSharingLocation()
        
        SwiftDataService.shared.updateLocationShareSession(
            remotePeerID: remotePeerID,
            remoteDisplayName: displayName,
            isSharingLocal: true,
            stateRaw: "SHARING"
        )
        reloadActiveSessions()
        
        saveChatLocationEvent(
            type: .locationSharingStarted,
            text: "Started sharing live location with \(displayName)",
            destinationID: remotePeerID,
            senderID: localNodeID,
            senderName: localName
        )
        
        // Immediate single coordinate broadcast snapshot
        broadcastCurrentLocationSnapshot(to: remotePeerID)
        AppLogger.location.info("[LocationShare] Started continuous location sharing with '\(displayName)' (\(remotePeerID))")
    }
    
    /// 4. Stop Sharing Location: Halts location updates and transmits LOCATION_SHARING_STOPPED packet
    public func stopSharingLocation(with remotePeerID: String, displayName: String) {
        let localNodeID = NodeIdentity.shared.nodeID
        let localName = NodeIdentity.shared.displayName
        
        let packet = LocationPacket(
            type: "LOCATION_SHARING_STOPPED",
            id: UUID(),
            senderID: localNodeID,
            senderName: localName,
            recipientID: remotePeerID,
            timestamp: Date(),
            accepted: nil,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            speed: nil,
            course: nil,
            sequenceNumber: nil,
            distanceMeters: nil,
            relativeBearing: nil,
            compassDirection: nil
        )
        
        sendLocationPacket(packet, destinationID: remotePeerID)
        
        SwiftDataService.shared.updateLocationShareSession(
            remotePeerID: remotePeerID,
            remoteDisplayName: displayName,
            isSharingLocal: false,
            stateRaw: "STOPPED"
        )
        reloadActiveSessions()
        
        saveChatLocationEvent(
            type: .locationSharingStopped,
            text: "Stopped sharing location with \(displayName)",
            destinationID: remotePeerID,
            senderID: localNodeID,
            senderName: localName
        )
        
        // Stop CoreLocation if no other active sharing sessions exist
        let allSessions = SwiftDataService.shared.fetchAllLocationShareSessions()
        if !allSessions.contains(where: { $0.isSharingLocal && $0.isActive }) {
            LocationService.shared.stopSharingLocation()
        }
        AppLogger.location.info("[LocationShare] Stopped location sharing with '\(displayName)'")
    }
    
    /// 5. Privacy-Preserving Relative Position Mode: Transmits ONLY relative vector data (zero raw GPS coordinates)
    public func shareRelativePosition(with remotePeerID: String, displayName: String) {
        let localNodeID = NodeIdentity.shared.nodeID
        let localName = NodeIdentity.shared.displayName
        
        guard let session = getSession(for: remotePeerID),
              let lat = session.lastRemoteLatitude,
              let lon = session.lastRemoteLongitude,
              let relInfo = LocationService.shared.relativeBearing(toLat: lat, lon: lon) else {
            AppLogger.location.warning("[RelativePosition] Cannot compute relative vector without target location for \(displayName)")
            return
        }
        
        let packet = LocationPacket(
            type: "RELATIVE_POSITION",
            id: UUID(),
            senderID: localNodeID,
            senderName: localName,
            recipientID: remotePeerID,
            timestamp: Date(),
            accepted: nil,
            latitude: nil, // Zero raw GPS coordinates transmitted
            longitude: nil,
            accuracy: nil,
            speed: nil,
            course: nil,
            sequenceNumber: nil,
            distanceMeters: relInfo.distanceMeters,
            relativeBearing: relInfo.relativeBearing,
            compassDirection: relInfo.compassDirection
        )
        
        sendLocationPacket(packet, destinationID: remotePeerID)
        
        let text = "Shared relative position (~\(relInfo.distanceFormatted) \(relInfo.compassDirection))"
        saveChatLocationEvent(
            type: .relativePosition,
            text: text,
            destinationID: remotePeerID,
            senderID: localNodeID,
            senderName: localName
        )
        AppLogger.location.info("[RelativePosition] Transmitted privacy-preserving relative vector to '\(displayName)'")
    }
    
    /// 6. Permission Revocation Hygiene: Halts all local sharing sessions when CoreLocation permission is revoked
    public func stopAllLocalSharing(reason: String) {
        let sessions = SwiftDataService.shared.fetchAllLocationShareSessions()
        let localSharing = sessions.filter { $0.isSharingLocal }
        for session in localSharing {
            stopSharingLocation(with: session.remotePeerID, displayName: session.remoteDisplayName)
        }
        LocationService.shared.stopSharingLocation()
        AppLogger.location.warning("[LocationShare] Revoked all local location sharing sessions: \(reason)")
    }
    
    // MARK: - Incoming Mesh Protocol Packet Processing
    
    public func processIncomingLocationPacket(_ message: Message) {
        guard let data = message.text.data(using: .utf8),
              let packet = try? JSONDecoder().decode(LocationPacket.self, from: data) else {
            return
        }
        
        AppLogger.location.info("[LocationPacket] Received '\(packet.type)' from '\(packet.senderName)' (\(packet.senderID))")
        
        let localNodeID = NodeIdentity.shared.nodeID
        
        switch packet.type {
        case "LOCATION_REQUEST":
            DispatchQueue.main.async {
                self.pendingIncomingRequests[packet.senderID] = packet.senderName
            }
            saveChatLocationEvent(
                type: .locationRequest,
                text: "\(packet.senderName) requested your location",
                destinationID: localNodeID,
                senderID: packet.senderID,
                senderName: packet.senderName
            )
            MeshNotificationManager.shared.postNotification(
                category: .messageReceived,
                title: "Location Request",
                body: "\(packet.senderName) requested your location.",
                deduplicationKey: "LOC_REQ_\(packet.id.uuidString)",
                peerID: packet.senderID
            )
            
        case "LOCATION_RESPONSE":
            let accepted = packet.accepted ?? false
            SwiftDataService.shared.updateLocationShareSession(
                remotePeerID: packet.senderID,
                remoteDisplayName: packet.senderName,
                isSharingRemote: accepted,
                stateRaw: accepted ? "ACTIVE" : "DENIED"
            )
            reloadActiveSessions()
            
            let text = accepted ? "\(packet.senderName) accepted your location request" : "\(packet.senderName) declined location request"
            saveChatLocationEvent(
                type: .locationResponse,
                text: text,
                destinationID: localNodeID,
                senderID: packet.senderID,
                senderName: packet.senderName
            )
            MeshNotificationManager.shared.postNotification(
                category: .messageReceived,
                title: accepted ? "Location Request Accepted" : "Location Request Declined",
                body: text,
                deduplicationKey: "LOC_RESP_\(packet.id.uuidString)",
                peerID: packet.senderID
            )
            
        case "LOCATION_UPDATE":
            guard let lat = packet.latitude, let lon = packet.longitude,
                  lat >= -90.0 && lat <= 90.0 && lon >= -180.0 && lon <= 180.0 else {
                AppLogger.location.error("[LocationPacket] Rejected invalid coordinate values lat=\(packet.latitude ?? 0), lon=\(packet.longitude ?? 0)")
                return
            }
            
            // Sequence Protection for Optional State:
            // 1. If lastRemoteSequenceNumber == nil -> ACCEPT first sequence number
            // 2. If seq > lastRemoteSequenceNumber! -> ACCEPT new sequence number
            // 3. If seq <= lastRemoteSequenceNumber! -> REJECT duplicate / out-of-order packet
            let session = getSession(for: packet.senderID)
            if let seq = packet.sequenceNumber {
                if let lastSeq = session?.lastRemoteSequenceNumber {
                    if seq <= lastSeq {
                        AppLogger.location.warning("[LocationPacket] Rejected out-of-order LOCATION_UPDATE seq=\(seq) <= lastRemoteSeq=\(lastSeq)")
                        return
                    }
                }
            }
            
            let acc = packet.accuracy ?? 10.0
            SwiftDataService.shared.updateLocationShareSession(
                remotePeerID: packet.senderID,
                remoteDisplayName: packet.senderName,
                isSharingRemote: true,
                lastRemoteLat: lat,
                lastRemoteLon: lon,
                lastRemoteAcc: acc,
                lastRemoteSpeed: packet.speed,
                lastRemoteCourse: packet.course,
                lastRemoteSeq: packet.sequenceNumber,
                stateRaw: "ACTIVE"
            )
            reloadActiveSessions()
            
            // Dispatch live update to Offline Navigation Engine
            let navTarget = NavigationTarget(
                id: packet.senderID,
                displayName: packet.senderName,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                altitude: nil,
                accuracy: acc,
                timestamp: packet.timestamp,
                speed: packet.speed,
                course: packet.course,
                sequenceNumber: packet.sequenceNumber ?? 0,
                targetType: .peer
            )
            OfflineNavigationService.shared.updateTargetCoordinate(navTarget)
            
        case "LOCATION_SHARING_STOPPED":
            SwiftDataService.shared.updateLocationShareSession(
                remotePeerID: packet.senderID,
                remoteDisplayName: packet.senderName,
                isSharingRemote: false,
                stateRaw: "STOPPED"
            )
            reloadActiveSessions()
            
            saveChatLocationEvent(
                type: .locationSharingStopped,
                text: "\(packet.senderName) stopped sharing location",
                destinationID: localNodeID,
                senderID: packet.senderID,
                senderName: packet.senderName
            )
            MeshNotificationManager.shared.postNotification(
                category: .messageReceived,
                title: "Location Sharing Stopped",
                body: "\(packet.senderName) stopped sharing their location.",
                deduplicationKey: "LOC_STOP_\(packet.id.uuidString)",
                peerID: packet.senderID
            )
            
        case "RELATIVE_POSITION":
            let distStr: String
            if let meters = packet.distanceMeters {
                distStr = meters < 1000 ? String(format: "%.0f m", meters) : String(format: "%.2f km", meters / 1000.0)
            } else {
                distStr = "nearby"
            }
            let dirStr = packet.compassDirection ?? "direction"
            let text = "\(packet.senderName) shared relative position (~\(distStr) \(dirStr))"
            
            saveChatLocationEvent(
                type: .relativePosition,
                text: text,
                destinationID: localNodeID,
                senderID: packet.senderID,
                senderName: packet.senderName
            )
            MeshNotificationManager.shared.postNotification(
                category: .messageReceived,
                title: "Relative Position Received",
                body: text,
                deduplicationKey: "REL_POS_\(packet.id.uuidString)",
                peerID: packet.senderID
            )
            
        default:
            break
        }
    }
    
    // MARK: - Expiration & Battery Engines
    
    private func startExpirationTimer() {
        expirationTimer?.invalidate()
        expirationTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkPendingRequestExpirations()
        }
    }
    
    private func checkPendingRequestExpirations() {
        let sessions = SwiftDataService.shared.fetchAllLocationShareSessions()
        let pending = sessions.filter { $0.stateRaw == "REQUEST_PENDING" }
        let now = Date()
        let localNodeID = NodeIdentity.shared.nodeID
        let localName = NodeIdentity.shared.displayName
        
        for session in pending {
            if now.timeIntervalSince(session.startedAt) >= 60.0 {
                SwiftDataService.shared.updateLocationShareSession(
                    remotePeerID: session.remotePeerID,
                    remoteDisplayName: session.remoteDisplayName,
                    stateRaw: "EXPIRED"
                )
                saveChatLocationEvent(
                    type: .locationExpired,
                    text: "Location request to \(session.remoteDisplayName) expired",
                    destinationID: session.remotePeerID,
                    senderID: localNodeID,
                    senderName: localName
                )
                AppLogger.location.info("[LocationRequest] Request to '\(session.remoteDisplayName)' expired after 60s")
            }
        }
        reloadActiveSessions()
    }
    
    // MARK: - Adaptive Location Broadcasting Engine
    
    private var lastBroadcastCoordinate: CLLocationCoordinate2D?
    private var lastBroadcastHeading: Double?
    private var currentBroadcastInterval: TimeInterval = 10.0
    
    /// Determines optimal broadcast interval based on movement speed and SOS state
    func calculateAdaptiveInterval(speedMetersPerSec: Double?, isSOSActive: Bool = false) -> TimeInterval {
        if isSOSActive {
            return 2.0 // High priority emergency updates
        }
        guard let speed = speedMetersPerSec, speed >= 0 else {
            return 10.0 // Default walking baseline
        }
        
        let speedKmh = speed * 3.6
        if speedKmh < 1.0 {
            return 30.0 // Stationary: conserve battery
        } else if speedKmh < 3.0 {
            return 15.0 // Slow walking
        } else if speedKmh < 7.0 {
            return 8.0  // Normal walking
        } else if speedKmh < 20.0 {
            return 5.0  // Running / cycling
        } else {
            return 3.0  // Fast vehicle movement
        }
    }
    
    private func startPeriodicBroadcastTimer(interval: TimeInterval = 10.0) {
        broadcastTimer?.invalidate()
        currentBroadcastInterval = interval
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.broadcastLocationToActiveSessions()
        }
    }
    
    /// Trigger immediate broadcast if user turns significantly (>30°) or jumps distance (>15m)
    func checkUrgentMovementTrigger(newCoord: CLLocationCoordinate2D, newHeading: Double?, speed: Double?) {
        if let lastCoord = lastBroadcastCoordinate {
            let dist = OfflineNavigationService.shared.calculateDistance(from: lastCoord, to: newCoord)
            if dist >= 15.0 {
                AppLogger.location.info("[AdaptiveBroadcast] Movement threshold exceeded (\(dist)m >= 15m), triggering instant broadcast")
                broadcastLocationToActiveSessions()
                return
            }
        }
        
        if let lastHead = lastBroadcastHeading, let currentHead = newHeading, let spd = speed, spd > 0.5 {
            let angleDiff = abs(CircularAngleHelper.shortestAngularDifference(from: lastHead, to: currentHead))
            if angleDiff >= 30.0 {
                AppLogger.location.info("[AdaptiveBroadcast] Heading shift threshold exceeded (\(angleDiff)° >= 30°), triggering instant broadcast")
                broadcastLocationToActiveSessions()
                return
            }
        }
    }
    
    private func broadcastLocationToActiveSessions() {
        let sessions = SwiftDataService.shared.fetchAllLocationShareSessions()
        let activeSharing = sessions.filter { $0.isSharingLocal && $0.isActive }
        guard !activeSharing.isEmpty else {
            // Idle reschedule
            startPeriodicBroadcastTimer(interval: 30.0)
            return
        }
        
        LocationService.shared.getCurrentLocationSnapshot { [weak self] location in
            guard let self = self else { return }
            guard let location = location else {
                self.startPeriodicBroadcastTimer(interval: 10.0)
                return
            }
            
            let lat = location.coordinate.latitude
            let lon = location.coordinate.longitude
            let acc = location.horizontalAccuracy
            let speed = location.speed >= 0 ? location.speed : nil
            let course = location.course >= 0 ? location.course : nil
            
            self.lastBroadcastCoordinate = location.coordinate
            if let heading = LocationService.shared.currentHeading {
                self.lastBroadcastHeading = heading
            }
            
            self.lock.lock()
            self.localSequenceNumber += 1
            let seqNo = self.localSequenceNumber
            self.lock.unlock()
            
            let localNodeID = NodeIdentity.shared.nodeID
            let localName = NodeIdentity.shared.displayName
            
            for session in activeSharing {
                let packet = LocationPacket(
                    type: "LOCATION_UPDATE",
                    id: UUID(),
                    senderID: localNodeID,
                    senderName: localName,
                    recipientID: session.remotePeerID,
                    timestamp: Date(),
                    accepted: nil,
                    latitude: lat,
                    longitude: lon,
                    accuracy: acc,
                    speed: speed,
                    course: course,
                    sequenceNumber: seqNo,
                    distanceMeters: nil,
                    relativeBearing: nil,
                    compassDirection: nil
                )
                
                self.sendLocationPacket(packet, destinationID: session.remotePeerID)
                SwiftDataService.shared.updateLocationShareSession(
                    remotePeerID: session.remotePeerID,
                    remoteDisplayName: session.remoteDisplayName,
                    lastLocalLat: lat,
                    lastLocalLon: lon,
                    lastLocalAcc: acc
                )
            }
            self.reloadActiveSessions()
            
            // Adapt next timer firing based on current velocity and emergency state
            let isSOSActive = MultipeerService.shared.currentStatus != .normal
            let nextInterval = self.calculateAdaptiveInterval(
                speedMetersPerSec: speed,
                isSOSActive: isSOSActive
            )
            self.startPeriodicBroadcastTimer(interval: nextInterval)
        }
    }
    
    private func broadcastCurrentLocationSnapshot(to remotePeerID: String) {
        LocationService.shared.getCurrentLocationSnapshot { [weak self] location in
            guard let self = self, let location = location else { return }
            let localNodeID = NodeIdentity.shared.nodeID
            let localName = NodeIdentity.shared.displayName
            
            let packet = LocationPacket(
                type: "LOCATION_UPDATE",
                id: UUID(),
                senderID: localNodeID,
                senderName: localName,
                recipientID: remotePeerID,
                timestamp: Date(),
                accepted: nil,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy,
                speed: location.speed >= 0 ? location.speed : nil,
                course: location.course >= 0 ? location.course : nil,
                sequenceNumber: 1,
                distanceMeters: nil,
                relativeBearing: nil,
                compassDirection: nil
            )
            self.sendLocationPacket(packet, destinationID: remotePeerID)
        }
    }
    
    private func sendLocationPacket(_ packet: LocationPacket, destinationID: String) {
        guard let jsonData = try? JSONEncoder().encode(packet),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        
        let localNodeID = NodeIdentity.shared.nodeID
        let localName = NodeIdentity.shared.displayName
        
        let p2pType: P2PMessageType
        switch packet.type {
        case "LOCATION_REQUEST": p2pType = .locationRequest
        case "LOCATION_RESPONSE": p2pType = .locationResponse
        case "LOCATION_SHARING_STOPPED": p2pType = .locationSharingStopped
        case "RELATIVE_POSITION": p2pType = .relativePosition
        default: p2pType = .chat
        }
        
        let msg = Message(
            id: packet.id,
            originID: localNodeID,
            destinationID: destinationID,
            senderID: localNodeID,
            senderName: localName,
            text: "LOCATION_PROTOCOL:\(jsonString)",
            timestamp: Date(),
            type: p2pType
        )
        
        let isConnected = MultipeerService.shared.connectedPeers.contains(where: { $0.id == destinationID })
        if isConnected {
            MultipeerService.shared.broadcast(message: msg)
        } else {
            if packet.type == "LOCATION_UPDATE" {
                AppLogger.location.info("[LocationShare] Discarding ephemeral LOCATION_UPDATE for offline peer \(destinationID)")
                return
            }
            // Queue control event for durable offline delivery
            _ = SwiftDataService.shared.savePendingMessage(
                messageID: packet.id,
                originID: localNodeID,
                destinationID: destinationID,
                recipientName: destinationID,
                senderName: localName,
                text: "LOCATION_PROTOCOL:\(jsonString)",
                channel: destinationID
            )
            AppLogger.location.info("[LocationShare] Queued control event '\(packet.type)' for offline peer \(destinationID)")
        }
    }
    
    private func saveChatLocationEvent(type: P2PMessageType, text: String, destinationID: String, senderID: String, senderName: String) {
        let msg = Message(
            id: UUID(),
            originID: senderID,
            destinationID: destinationID,
            senderID: senderID,
            senderName: senderName,
            text: text,
            timestamp: Date(),
            type: type
        )
        _ = SwiftDataService.shared.saveMessage(msg)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .didReceiveChatMessage, object: nil)
        }
    }
}
