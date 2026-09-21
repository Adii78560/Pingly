//
//  RelaynTransportLogger.swift
//  Relayn
//
//  Created by Senior iOS Developer on 13/08/26.
//

import Foundation
import Combine
import CryptoKit
import os

#if DEBUG

struct SessionLifecycleEvent: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let tag: String
    let event: String
    let peer: String
    let details: String
    
    var formattedString: String {
        let timeStr = timestamp.logTimeString
        let shortPeer = String(peer.prefix(6))
        return "[\(timeStr)] [\(event)] peer=\(shortPeer) \(details)"
    }
}

/// Thread-safe in-memory diagnostic metrics counter
final class RelaynTransportDiagnosticsManager: ObservableObject {
    static let shared = RelaynTransportDiagnosticsManager()
    static let physicalTestRunID: String = String(UUID().uuidString.prefix(6)).uppercased()
    
    private let lock = NSLock()
    @Published private(set) var testRunID: String = RelaynTransportDiagnosticsManager.physicalTestRunID
    @Published private(set) var connectedPeersCount: Int = 0
    @Published private(set) var txFramesCount: Int = 0
    @Published private(set) var rxFramesCount: Int = 0
    @Published private(set) var decodeSuccessCount: Int = 0
    @Published private(set) var decodeFailuresCount: Int = 0
    @Published private(set) var ackSentCount: Int = 0
    @Published private(set) var ackReceivedCount: Int = 0
    @Published private(set) var ackMatchedCount: Int = 0
    @Published private(set) var ackUnmatchedCount: Int = 0
    @Published private(set) var relayReceivedCount: Int = 0
    @Published private(set) var relayForwardedCount: Int = 0
    @Published private(set) var relayDroppedCount: Int = 0
    @Published private(set) var queueFailedCount: Int = 0
    @Published private(set) var queueDeliveredCount: Int = 0
    
    // Physical Test Diagnostics Counter tracking
    @Published private(set) var physicalTestMessagesSentCount: Int = 0
    @Published private(set) var physicalTestMessagesReceivedCount: Int = 0
    @Published private(set) var physicalTestMessagesACKedCount: Int = 0
    @Published private(set) var physicalTestMessageFailuresCount: Int = 0
    @Published private(set) var physicalTestPTTSessionsCount: Int = 0
    @Published private(set) var physicalTestPTTTxFramesCount: Int = 0
    @Published private(set) var physicalTestPTTRxFramesCount: Int = 0
    @Published private(set) var physicalTestPTTDroppedFramesCount: Int = 0
    @Published private(set) var physicalTestPTTDecodeFailuresCount: Int = 0
    
    // Live pipeline tracking for MeshDiagnosticsView UI
    @Published private(set) var lastOutgoingMessageID: String = "None"
    @Published private(set) var lastIncomingMessageID: String = "None"
    @Published private(set) var lastConnectedPeerID: String = "None"
    @Published private(set) var lastSendResult: String = "None"
    @Published private(set) var lastReceiveResult: String = "None"
    @Published private(set) var lastDecodeResult: String = "None"
    @Published private(set) var lastACKResult: String = "None"
    
    // Objective 6 & 7: Connection Health & Bounded Session Lifecycle Timeline Buffer (Last 100 Events)
    @Published private(set) var recentLifecycleEvents: [SessionLifecycleEvent] = []
    @Published private(set) var currentMCSessionState: String = "NOT_CONNECTED"
    @Published private(set) var connectedPeersList: [String] = []
    @Published private(set) var connectionEstablishedTimestamp: Date? = nil
    @Published private(set) var lastTxTimestamp: Date? = nil
    @Published private(set) var lastRxTimestamp: Date? = nil
    @Published private(set) var lastPTTTxTimestamp: Date? = nil
    @Published private(set) var lastPTTRxTimestamp: Date? = nil
    @Published private(set) var lastSessionStateChangeTimestamp: Date? = nil
    @Published private(set) var lastSocketError: String = "None"
    @Published private(set) var disconnectCount: Int = 0
    @Published private(set) var reconnectCount: Int = 0
    
    private init() {}
    
    func recordPhysicalTestEvent(category: String = "SessionLifecycle", event: String, peer: String = "N/A", details: String = "") {
        lock.lock()
        let runID = RelaynTransportDiagnosticsManager.physicalTestRunID
        let deviceFingerprint = String(KeychainIdentityService.shared.fetchOrCreateDeviceID().uuidString.prefix(6))
        let shortPeer = String(peer.prefix(6))
        
        let logLine = "[PhysicalTest][run=\(runID)][device=\(deviceFingerprint)][\(category)] \(event) peer=\(shortPeer) \(details)"
        
        let newEvent = SessionLifecycleEvent(tag: category, event: event, peer: peer, details: details)
        lock.unlock()
        
        DispatchQueue.main.async {
            self.recentLifecycleEvents.append(newEvent)
            if self.recentLifecycleEvents.count > 100 {
                self.recentLifecycleEvents.removeFirst(self.recentLifecycleEvents.count - 100)
            }
        }
    }
    
    func resetPhysicalTestDiagnostics() {
        lock.lock()
        lock.unlock()
        
        DispatchQueue.main.async {
            self.physicalTestMessagesSentCount = 0
            self.physicalTestMessagesReceivedCount = 0
            self.physicalTestMessagesACKedCount = 0
            self.physicalTestMessageFailuresCount = 0
            self.physicalTestPTTSessionsCount = 0
            self.physicalTestPTTTxFramesCount = 0
            self.physicalTestPTTRxFramesCount = 0
            self.physicalTestPTTDroppedFramesCount = 0
            self.physicalTestPTTDecodeFailuresCount = 0
            self.disconnectCount = 0
            self.reconnectCount = 0
            self.lastSocketError = "None"
            self.recentLifecycleEvents.removeAll()
            self.recordPhysicalTestEvent(category: "Diagnostics", event: "TEST_RUN_METRICS_RESET", peer: "N/A", details: "counters_cleared")
        }
    }
    
    func incrementPhysicalTestSent() {
        DispatchQueue.main.async { self.physicalTestMessagesSentCount += 1 }
    }
    
    func incrementPhysicalTestReceived() {
        DispatchQueue.main.async { self.physicalTestMessagesReceivedCount += 1 }
    }
    
    func incrementPhysicalTestACKed() {
        DispatchQueue.main.async { self.physicalTestMessagesACKedCount += 1 }
    }
    
    func incrementPhysicalTestMessageFailures() {
        DispatchQueue.main.async { self.physicalTestMessageFailuresCount += 1 }
    }
    
    func incrementPhysicalTestPTTSessions() {
        DispatchQueue.main.async { self.physicalTestPTTSessionsCount += 1 }
    }
    
    func addPhysicalTestPTTTxFrames(count: Int) {
        DispatchQueue.main.async { self.physicalTestPTTTxFramesCount += count }
    }
    
    func addPhysicalTestPTTRxFrames(count: Int) {
        DispatchQueue.main.async { self.physicalTestPTTRxFramesCount += count }
    }
    
    func addPhysicalTestPTTDroppedFrames(count: Int) {
        DispatchQueue.main.async { self.physicalTestPTTDroppedFramesCount += count }
    }
    
    func recordLifecycleEvent(event: String, peer: String = "N/A", details: String = "") {
        lock.lock()
        let newEvent = SessionLifecycleEvent(tag: "SessionLifecycle", event: event, peer: peer, details: details)
        
        lock.unlock()
        
        DispatchQueue.main.async {
            self.recentLifecycleEvents.append(newEvent)
            if self.recentLifecycleEvents.count > 100 {
                self.recentLifecycleEvents.removeFirst(self.recentLifecycleEvents.count - 100)
            }
            if event == "CONNECTED" {
                self.reconnectCount += 1
                self.currentMCSessionState = "CONNECTED"
                self.connectionEstablishedTimestamp = Date()
                self.lastSessionStateChangeTimestamp = Date()
            } else if event == "SESSION_DISCONNECT" || event == "NOT_CONNECTED" {
                self.disconnectCount += 1
                self.currentMCSessionState = "NOT_CONNECTED"
                self.lastSessionStateChangeTimestamp = Date()
            } else if event == "CONNECTING" {
                self.currentMCSessionState = "CONNECTING"
                self.lastSessionStateChangeTimestamp = Date()
            }
        }
    }
    
    func recordSocketOrStreamError(errorDescription: String, domain: String = "NSPOSIXErrorDomain", code: Int = 54) {
        lock.lock()
        let errDetails = "domain=\(domain) code=\(code) \(errorDescription)"
        lock.unlock()
        
        recordLifecycleEvent(event: "SOCKET_ERROR", details: errDetails)
        
        DispatchQueue.main.async {
            self.lastSocketError = errDetails
        }
    }
    
    func updateTxTimestamp() {
        DispatchQueue.main.async {
            self.lastTxTimestamp = Date()
        }
    }
    
    func updateRxTimestamp() {
        DispatchQueue.main.async {
            self.lastRxTimestamp = Date()
        }
    }
    
    func updatePTTTxTimestamp() {
        DispatchQueue.main.async {
            self.lastPTTTxTimestamp = Date()
        }
    }
    
    func updatePTTRxTimestamp() {
        DispatchQueue.main.async {
            self.lastPTTRxTimestamp = Date()
        }
    }
    
    func updateConnectedPeersList(_ peers: [String]) {
        DispatchQueue.main.async {
            self.connectedPeersList = peers
            self.connectedPeersCount = peers.count
        }
    }
    
    func recordOutgoingMessage(id: UUID, peer: String, result: String) {
        lock.lock()
        let shortID = String(id.uuidString.prefix(6)).uppercased()
        let shortPeer = String(peer.prefix(6))
        let sendRes = "\(result) (\(shortPeer))"
        lock.unlock()
        
        DispatchQueue.main.async {
            self.lastOutgoingMessageID = shortID
            self.lastSendResult = sendRes
        }
    }
    
    func recordIncomingMessage(id: UUID?, peer: String, result: String, decodeRes: String? = nil) {
        lock.lock()
        let shortID = id != nil ? String(id!.uuidString.prefix(6)).uppercased() : "UNKNOWN"
        let shortPeer = String(peer.prefix(6))
        let rxRes = "\(result) (\(shortPeer))"
        let decRes = decodeRes ?? "Success"
        lock.unlock()
        
        DispatchQueue.main.async {
            self.lastIncomingMessageID = shortID
            self.lastReceiveResult = rxRes
            self.lastDecodeResult = decRes
        }
    }
    
    func recordACKEvent(id: UUID, peer: String, result: String) {
        lock.lock()
        let shortID = String(id.uuidString.prefix(6)).uppercased()
        let shortPeer = String(peer.prefix(6))
        let ackRes = "\(result) for \(shortID) (\(shortPeer))"
        lock.unlock()
        
        DispatchQueue.main.async {
            self.lastACKResult = ackRes
        }
    }
    
    func recordPeerConnection(peer: String) {
        lock.lock()
        let shortPeer = String(peer.prefix(6))
        lock.unlock()
        
        DispatchQueue.main.async {
            self.lastConnectedPeerID = shortPeer
        }
    }
    
    func updateConnectedPeers(count: Int) {
        lock.lock()
        defer { lock.unlock() }
        connectedPeersCount = count
    }
    
    func incrementTxFrames() {
        lock.lock()
        defer { lock.unlock() }
        txFramesCount += 1
    }
    
    func incrementRxFrames() {
        lock.lock()
        defer { lock.unlock() }
        rxFramesCount += 1
    }
    
    func incrementDecodeSuccess() {
        lock.lock()
        defer { lock.unlock() }
        decodeSuccessCount += 1
    }
    
    func incrementDecodeFailures() {
        lock.lock()
        defer { lock.unlock() }
        decodeFailuresCount += 1
    }
    
    func incrementAckSent() {
        lock.lock()
        defer { lock.unlock() }
        ackSentCount += 1
    }
    
    func incrementAckReceived() {
        lock.lock()
        defer { lock.unlock() }
        ackReceivedCount += 1
    }
    
    func incrementAckMatched() {
        lock.lock()
        defer { lock.unlock() }
        ackMatchedCount += 1
    }
    
    func incrementAckUnmatched() {
        lock.lock()
        defer { lock.unlock() }
        ackUnmatchedCount += 1
    }
    
    func incrementRelayReceived() {
        lock.lock()
        defer { lock.unlock() }
        relayReceivedCount += 1
    }
    
    func incrementRelayForwarded() {
        lock.lock()
        defer { lock.unlock() }
        relayForwardedCount += 1
    }
    
    func incrementRelayDropped() {
        lock.lock()
        defer { lock.unlock() }
        relayDroppedCount += 1
    }
    
    func incrementQueueFailed() {
        lock.lock()
        defer { lock.unlock() }
        queueFailedCount += 1
    }
    
    func incrementQueueDelivered() {
        lock.lock()
        defer { lock.unlock() }
        queueDeliveredCount += 1
    }
    
    func logDiagnosticSummary() {
        lock.lock()
        defer { lock.unlock() }
        let summary = """
        [PINGLY_TRANSPORT_DIAGNOSTICS]
        connectedPeers=\(connectedPeersCount)
        txFrames=\(txFramesCount)
        rxFrames=\(rxFramesCount)
        decodeSuccess=\(decodeSuccessCount)
        decodeFailures=\(decodeFailuresCount)
        ackSent=\(ackSentCount)
        ackReceived=\(ackReceivedCount)
        ackMatched=\(ackMatchedCount)
        ackUnmatched=\(ackUnmatchedCount)
        relayReceived=\(relayReceivedCount)
        relayForwarded=\(relayForwardedCount)
        relayDropped=\(relayDroppedCount)
        queueFailed=\(queueFailedCount)
        queueDelivered=\(queueDeliveredCount)
        """
    }
}

/// Helper methods for forensic logging of Relayn mesh networking bytes and frames
enum RelaynTransportLogger {
    
    static func sha256Hex(data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    static func hexPreview(data: Data, maxBytes: Int = 128) -> String {
        let count = min(data.count, maxBytes)
        let slice = data.prefix(count)
        let hexString = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
        if data.count > maxBytes {
            return "\(hexString) ... [\(data.count - maxBytes) bytes truncated]"
        }
        return hexString
    }
    
    static func utf8Preview(data: Data, maxBytes: Int = 128) -> String {
        let slice = data.prefix(maxBytes)
        if let str = String(data: slice, encoding: .utf8) {
            let sanitized = str.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            if data.count > maxBytes {
                return "\"\(sanitized)...\" [\(data.count) total bytes]"
            }
            return "\"\(sanitized)\""
        }
        return "NON_UTF8_BINARY_DATA"
    }
    
    static func currentQueueName() -> String {
        if Thread.isMainThread {
            return "main"
        }
        if let name = OperationQueue.current?.underlyingQueue?.label, !name.isEmpty {
            return name
        }
        if let name = String(validatingUTF8: __dispatch_queue_get_label(nil)), !name.isEmpty {
            return name
        }
        return "unknown"
    }
    
    static func currentThreadDescription() -> String {
        return "Thread:\(Thread.current) (Queue:\(currentQueueName()))"
    }
    
    static func formatDecodingError(_ error: Error) -> (description: String, codingPath: String) {
        if let decError = error as? DecodingError {
            switch decError {
            case .typeMismatch(let type, let context):
                let path = context.codingPath.map { $0.stringValue }.joined(separator: " -> ")
                return ("DecodingError.typeMismatch (\(type)): \(context.debugDescription)", path.isEmpty ? "ROOT" : path)
            case .valueNotFound(let type, let context):
                let path = context.codingPath.map { $0.stringValue }.joined(separator: " -> ")
                return ("DecodingError.valueNotFound (\(type)): \(context.debugDescription)", path.isEmpty ? "ROOT" : path)
            case .keyNotFound(let key, let context):
                let path = (context.codingPath + [key]).map { $0.stringValue }.joined(separator: " -> ")
                return ("DecodingError.keyNotFound (\(key.stringValue)): \(context.debugDescription)", path.isEmpty ? "ROOT" : path)
            case .dataCorrupted(let context):
                let path = context.codingPath.map { $0.stringValue }.joined(separator: " -> ")
                return ("DecodingError.dataCorrupted: \(context.debugDescription)", path.isEmpty ? "ROOT" : path)
            @unknown default:
                return ("DecodingError.unknown: \(error.localizedDescription)", "N/A")
            }
        }
        return (error.localizedDescription, "N/A")
    }
}


#else

// MARK: - Release No-Op Stubs
struct SessionLifecycleEvent: Identifiable {
    let id = UUID()
    let timestamp = Date()
}

final class RelaynTransportDiagnosticsManager: ObservableObject {
    static let shared = RelaynTransportDiagnosticsManager()
    @Published private(set) var testRunID: String = "RELEASE"
    @Published private(set) var currentMCSessionState: String = "NOT_CONNECTED"
    @Published private(set) var connectedPeersCount: Int = 0
    @Published private(set) var connectedPeersList: [String] = []
    @Published private(set) var lastSocketError: String = "None"
    @Published private(set) var disconnectCount: Int = 0
    private init() {}
    @inline(__always) func recordPhysicalTestEvent(category: String = "SessionLifecycle", event: String, peer: String = "N/A", details: String = "") {}
    @inline(__always) func resetPhysicalTestDiagnostics() {}
    @inline(__always) func incrementPhysicalTestSent() {}
    @inline(__always) func incrementPhysicalTestReceived() {}
    @inline(__always) func incrementPhysicalTestACKed() {}
    @inline(__always) func incrementPhysicalTestMessageFailures() {}
    @inline(__always) func incrementPhysicalTestPTTSessions() {}
    @inline(__always) func addPhysicalTestPTTTxFrames(count: Int) {}
    @inline(__always) func addPhysicalTestPTTRxFrames(count: Int) {}
    @inline(__always) func addPhysicalTestPTTDroppedFrames(count: Int) {}
    @inline(__always) func recordLifecycleEvent(event: String, peer: String = "N/A", details: String = "") {}
    @inline(__always) func recordSocketOrStreamError(errorDescription: String, domain: String = "NSPOSIXErrorDomain", code: Int = 54) {}
    @inline(__always) func updateTxTimestamp() {}
    @inline(__always) func updateRxTimestamp() {}
    @inline(__always) func updatePTTTxTimestamp() {}
    @inline(__always) func updatePTTRxTimestamp() {}
    @inline(__always) func updateConnectedPeersList(_ peers: [String]) {}
    @inline(__always) func recordOutgoingMessage(id: UUID, peer: String, result: String) {}
    @inline(__always) func recordIncomingMessage(id: UUID?, peer: String, result: String, decodeRes: String? = nil) {}
    @inline(__always) func recordACKEvent(id: UUID, peer: String, result: String) {}
    @inline(__always) func recordPeerConnection(peer: String) {}
    @inline(__always) func updateConnectedPeers(count: Int) {}
    @inline(__always) func incrementTxFrames() {}
    @inline(__always) func incrementRxFrames() {}
    @inline(__always) func incrementDecodeSuccess() {}
    @inline(__always) func incrementDecodeFailures() {}
    @inline(__always) func incrementAckSent() {}
    @inline(__always) func incrementAckReceived() {}
    @inline(__always) func incrementAckMatched() {}
    @inline(__always) func incrementAckUnmatched() {}
    @inline(__always) func incrementRelayReceived() {}
    @inline(__always) func incrementRelayForwarded() {}
    @inline(__always) func incrementRelayDropped() {}
    @inline(__always) func incrementQueueFailed() {}
    @inline(__always) func incrementQueueDelivered() {}
    @inline(__always) func logDiagnosticSummary() {}
}

enum RelaynTransportLogger {
    @inline(__always) static func sha256Hex(data: Data) -> String  { return "" }
    @inline(__always) static func hexPreview(data: Data, maxBytes: Int = 128) -> String  { return "" }
    @inline(__always) static func utf8Preview(data: Data, maxBytes: Int = 128) -> String  { return "" }
    @inline(__always) static func currentQueueName() -> String  { return "" }
    @inline(__always) static func currentThreadDescription() -> String  { return "" }
    @inline(__always) static func formatDecodingError(_ error: Error) -> (description: String, codingPath: String)  { return ("", "") }
}

#endif
