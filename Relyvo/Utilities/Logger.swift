//
//  Logger.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import os

/// Production Logger wrapper using Swift `os.Logger` for unified, high-performance structured logging.
enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.RaiEnterprise.Relyvo"
    
    static let general = Logger(subsystem: subsystem, category: "General")
    static let multipeer = Logger(subsystem: subsystem, category: "MultipeerMesh")
    static let ble = Logger(subsystem: subsystem, category: "BLEBeacon")
    static let audio = Logger(subsystem: subsystem, category: "RadioAudio")
    static let location = Logger(subsystem: subsystem, category: "Location")
    static let emergency = Logger(subsystem: subsystem, category: "EmergencySOS")
    static let notifications = Logger(subsystem: "com.relayn.mesh.notifications", category: "MeshNotifications")
    
    /// Safe 6-character device fingerprint tag for structured device logs: `[Device=4B44FA]`
    @MainActor static var deviceTag: String {
        let fullID = KeychainIdentityService.shared.fetchOrCreateDeviceID().uuidString
        let shortID = String(fullID.prefix(6)).uppercased()
        return "[Device=\(shortID)]"
    }
    
    /// Returns formatted correlation message tag: `[Device=4B44FA][MessagePipeline][messageID=8F31A2]`
    static func messageTag(_ messageID: UUID, category: String = "MessagePipeline") -> String {
        let shortID = String(messageID.uuidString.prefix(6)).uppercased()
        return "\(deviceTag)[\(category)][messageID=\(shortID)]"
    }
    
    /// Returns formatted peer tag: `[Device=4B44FA][PeerPipeline]`
    static var peerTag: String {
        return "\(deviceTag)[PeerPipeline]"
    }
    
    /// Returns formatted transport tag: `[Device=4B44FA][TransportPipeline]`
    static func transportTag(_ messageID: UUID? = nil) -> String {
        if let id = messageID {
            let shortID = String(id.uuidString.prefix(6)).uppercased()
            return "\(deviceTag)[TransportPipeline][messageID=\(shortID)]"
        } else {
            return "\(deviceTag)[TransportPipeline]"
        }
    }
    
    /// Returns formatted frame tag: `[Device=4B44FA][FramePipeline]`
    static func frameTag(_ messageID: UUID? = nil) -> String {
        if let id = messageID {
            let shortID = String(id.uuidString.prefix(6)).uppercased()
            return "\(deviceTag)[FramePipeline][messageID=\(shortID)]"
        } else {
            return "\(deviceTag)[FramePipeline]"
        }
    }
    
    /// Returns formatted routing tag: `[Device=4B44FA][RoutingPipeline]`
    static func routingTag(_ messageID: UUID) -> String {
        let shortID = String(messageID.uuidString.prefix(6)).uppercased()
        return "\(deviceTag)[RoutingPipeline][messageID=\(shortID)]"
    }
    
    /// Returns formatted ACK tag: `[Device=4B44FA][ACKPipeline][messageID=8F31A2]`
    static func ackTag(_ messageID: UUID) -> String {
        let shortID = String(messageID.uuidString.prefix(6)).uppercased()
        return "\(deviceTag)[ACKPipeline][messageID=\(shortID)]"
    }
}
