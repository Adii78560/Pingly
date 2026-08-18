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

/// Thread-safe in-memory diagnostic metrics counter
final class RelaynTransportDiagnosticsManager: ObservableObject {
    static let shared = RelaynTransportDiagnosticsManager()
    
    private let lock = NSLock()
    
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
    
    // Live pipeline tracking for MeshDiagnosticsView UI
    @Published private(set) var lastOutgoingMessageID: String = "None"
    @Published private(set) var lastIncomingMessageID: String = "None"
    @Published private(set) var lastConnectedPeerID: String = "None"
    @Published private(set) var lastSendResult: String = "None"
    @Published private(set) var lastReceiveResult: String = "None"
    @Published private(set) var lastDecodeResult: String = "None"
    @Published private(set) var lastACKResult: String = "None"
    
    private init() {}
    
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
        AppLogger.multipeer.info("\(summary)")
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
