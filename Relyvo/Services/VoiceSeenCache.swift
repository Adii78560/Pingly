//
//  VoiceSeenCache.swift
//  Relayn
//
//  Thread-safe bounded memory cache for PTT voice deduplication.
//  Keys by SenderNodeID + SessionID + SequenceNo.
//

import Foundation

struct VoiceFrameKey: Hashable {
    let senderNodeID: UUID
    let sessionID: UUID
    let sequenceNo: UInt16
}

final class VoiceSeenCache {
    static let shared = VoiceSeenCache()
    
    // max sessions tracking to prevent unbounded memory
    private let maxSessions = 5
    // max frames per session (500 frames = ~10 seconds of history at 50fps)
    private let maxFramesPerSession = 500
    // how long to keep a session alive without new frames
    private let sessionTTLSeconds: TimeInterval = 10.0
    
    private let lock = NSLock()
    
    private struct SessionContext {
        var lastUpdated: Date
        var seenSequenceNos: Set<UInt16>
    }
    
    // Key is senderNodeID + sessionID combined string for simplicity, or just a custom struct
    private struct SessionKey: Hashable {
        let senderNodeID: UUID
        let sessionID: UUID
    }
    
    private var sessions: [SessionKey: SessionContext] = [:]
    
    private init() {}
    
    func contains(senderNodeID: UUID, sessionID: UUID, sequenceNo: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let sessionKey = SessionKey(senderNodeID: senderNodeID, sessionID: sessionID)
        return sessions[sessionKey]?.seenSequenceNos.contains(sequenceNo) ?? false
    }
    
    func insert(senderNodeID: UUID, sessionID: UUID, sequenceNo: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        
        evictExpiredSessionsLocked()
        
        let sessionKey = SessionKey(senderNodeID: senderNodeID, sessionID: sessionID)
        var context = sessions[sessionKey] ?? SessionContext(lastUpdated: Date(), seenSequenceNos: [])
        
        context.lastUpdated = Date()
        context.seenSequenceNos.insert(sequenceNo)
        
        if context.seenSequenceNos.count > maxFramesPerSession {
            // Rough capacity cap: drop the oldest tracking
            if let minSeq = context.seenSequenceNos.min() {
                context.seenSequenceNos.remove(minSeq)
            }
        }
        
        sessions[sessionKey] = context
        
        // Enforce max active sessions
        if sessions.count > maxSessions {
            if let oldestSession = sessions.min(by: { $0.value.lastUpdated < $1.value.lastUpdated }) {
                sessions.removeValue(forKey: oldestSession.key)
            }
        }
    }
    
    func sessionEnded(senderNodeID: UUID, sessionID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let sessionKey = SessionKey(senderNodeID: senderNodeID, sessionID: sessionID)
        sessions.removeValue(forKey: sessionKey)
    }
    
    private func evictExpiredSessionsLocked() {
        let cutoff = Date().addingTimeInterval(-sessionTTLSeconds)
        sessions = sessions.filter { $0.value.lastUpdated > cutoff }
    }
}
