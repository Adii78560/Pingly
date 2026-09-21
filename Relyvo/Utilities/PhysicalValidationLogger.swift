//
//  PhysicalValidationLogger.swift
//  Relyvo
//
//  Created by Antigravity on 18/09/26.
//

import Foundation
import Combine
import os

#if DEBUG

/// Specific event categories for the Physical Validation Campaign checklist.
enum ValidationEventType: String {
    case meshRx = "[MESH_RX]"
    case meshForward = "[MESH_FORWARD]"
    case meshDedupDrop = "[MESH_DEDUP_DROP]"
    case meshLoopDrop = "[MESH_LOOP_DROP]"
    case meshTtlDrop = "[MESH_TTL_DROP]"
    case meshDelivered = "[MESH_DELIVERED]"
    case meshAck = "[MESH_ACK]"
    case meshQueue = "[MESH_QUEUE]"
    case peerDiscovered = "[MESH_PEER_DISCOVERED]"
    case peerConnected = "[MESH_PEER_CONNECTED]"
    case peerDisconnected = "[MESH_PEER_DISCONNECTED]"
    case chatAuthDrop = "[MESH_CHAT_AUTH_DROP]"
    case chatQueueAuthDrop = "[MESH_CHAT_QUEUE_AUTH_DROP]"
}

struct ValidationLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let type: ValidationEventType
    let message: String
}

@MainActor
final class PhysicalValidationLogger: ObservableObject {
    static let shared = PhysicalValidationLogger()
    
    @Published var logs: [ValidationLogEntry] = []
    @Published var isOverlayVisible: Bool = false
    
    private let maxLogs = 200
    
    private init() {}
    
    func log(type: ValidationEventType, _ message: String) {
        let entry = ValidationLogEntry(type: type, message: message)
        
        // Ensure UI updates happen on MainActor
        Task { @MainActor in
            self.logs.append(entry)
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst(self.logs.count - self.maxLogs)
            }
            
            // Mirror to OSLog for Xcode console
            AppLogger.multipeer.debug("\(type.rawValue) \(message)")
        }
    }
    
    func clear() {
        logs.removeAll()
    }
}


#else

// MARK: - Release No-Op Stubs
enum ValidationEventType: String {
    case meshRx, meshForward, meshDedupDrop, meshLoopDrop, meshTtlDrop, meshDelivered, meshAck, meshQueue, peerDiscovered, peerConnected, peerDisconnected, chatAuthDrop, chatQueueAuthDrop
}

struct ValidationLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let type: ValidationEventType
    let message: String
}

@MainActor
final class PhysicalValidationLogger: ObservableObject {
    static let shared = PhysicalValidationLogger()
    
    @Published var logs: [ValidationLogEntry] = []
    @Published var isOverlayVisible: Bool = false
    
    private init() {}
    
    @inline(__always) func log(type: ValidationEventType, _ message: String) {}
    @inline(__always) func clear() {}
}

#endif
