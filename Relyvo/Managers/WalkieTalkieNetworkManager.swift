//
//  WalkieTalkieNetworkManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import MultipeerConnectivity
import Combine
import os


enum PTTFrameType: UInt8 {
    case start = 0x01
    case chunk = 0x02
    case end   = 0x03
}

/// Extended 11-Byte PTT Binary Header
/// Format: [1 Byte Type] + [2 Bytes SequenceNo] + [4 Bytes TimestampMs] + [4 Bytes SenderHash]
struct PTTFrameHeader {
    let type: PTTFrameType   // 1 Byte
    let sequenceNo: UInt16   // 2 Bytes (wraps at 65535)
    let timestampMs: UInt32  // 4 Bytes (ms elapsed since PTT_START)
    let senderHash: UInt32   // 4 Bytes
    
    static let headerSize: Int = 11
    
    func encode() -> Data {
        var data = Data(capacity: PTTFrameHeader.headerSize)
        var typeByte = type.rawValue
        var seqBE = sequenceNo.bigEndian
        var timeBE = timestampMs.bigEndian
        var senderBE = senderHash.bigEndian
        
        data.append(&typeByte, count: 1)
        data.append(Data(bytes: &seqBE, count: 2))
        data.append(Data(bytes: &timeBE, count: 4))
        data.append(Data(bytes: &senderBE, count: 4))
        return data
    }
    
    static func decode(from data: Data) -> PTTFrameHeader? {
        guard data.count >= PTTFrameHeader.headerSize else { return nil }
        let typeRaw = data[0]
        guard let frameType = PTTFrameType(rawValue: typeRaw) else { return nil }
        
        let seqBE = data.subdata(in: 1..<3).withUnsafeBytes { $0.load(as: UInt16.self) }
        let timeBE = data.subdata(in: 3..<7).withUnsafeBytes { $0.load(as: UInt32.self) }
        let senderBE = data.subdata(in: 7..<11).withUnsafeBytes { $0.load(as: UInt32.self) }
        
        return PTTFrameHeader(
            type: frameType,
            sequenceNo: UInt16(bigEndian: seqBE),
            timestampMs: UInt32(bigEndian: timeBE),
            senderHash: UInt32(bigEndian: senderBE)
        )
    }
}

/// Floor control network manager implementing half-duplex state machine and 11-byte binary framing protocol.
final class WalkieTalkieNetworkManager: NSObject, ObservableObject, AudioStreamEngineDelegate {
    
    static let shared = WalkieTalkieNetworkManager()
    
    @Published var activeFloorSenderID: String? = nil
    @Published var isFloorLockedBySelf: Bool = false
    
    private var multipeerService: MultipeerService {
        return MultipeerService.shared
    }
    
    // Sender Sequence & Session Timers
    private var sessionSequenceNo: UInt16 = 0
    private var sessionStartTime: Date? = nil
    private let mySenderIDHash: UInt32 = UInt32(truncatingIfNeeded: Locale.current.identifier.hashValue)
    
    // Receiver Diagnostics (Loss, Reordering & Jitter Tracking)
    private var lastReceivedSequenceNo: UInt16? = nil
    private var lastReceivedTimestampMs: UInt32 = 0
    private var lastArrivalRealTime: Date? = nil
    private(set) var totalDroppedFramesCount: Int = 0
    private(set) var totalOutofOrderFramesCount: Int = 0
    
    override init() {
        super.init()
        AudioStreamEngine.shared.delegate = self
        setupPacketReceiver()
    }
    
    // MARK: - Floor Control Actions
    
    /// Requests the floor, notifies peer nodes, and begins recording stream.
    func acquireFloor(targetPeer: PeerDevice? = nil) -> Bool {
        guard activeFloorSenderID == nil else {
            AppLogger.multipeer.warning("Floor locked by peer: \(self.activeFloorSenderID ?? "")")
            return false
        }
        
        BackgroundAudioSessionManager.shared.beginBackgroundTask()
        isFloorLockedBySelf = true
        activeFloorSenderID = "LOCAL_SELF"
        sessionSequenceNo = 0
        sessionStartTime = Date()
        
        // Send PTT_START packet to remote peers
        sendPTTPacket(type: .start, payload: Data())
        
        // Start live low-latency capture
        let started = AudioStreamEngine.shared.startCapture()
        return started
    }
    
    /// Releases the floor, sends PTT_END frame, and stops microphone recording.
    func releaseFloor(targetPeer: PeerDevice? = nil) {
        guard isFloorLockedBySelf else { return }
        
        AudioStreamEngine.shared.stopCapture()
        
        // Send PTT_END packet to remote peer
        sendPTTPacket(type: .end, payload: Data())
        
        isFloorLockedBySelf = false
        activeFloorSenderID = nil
        sessionStartTime = nil
        BackgroundAudioSessionManager.shared.endBackgroundTask()
    }
    
    // MARK: - Audio Stream Delegate
    
    func audioStreamEngine(_ engine: AudioStreamEngine, didCaptureAudioChunk chunkData: Data) {
        guard isFloorLockedBySelf else { return }
        sessionSequenceNo = sessionSequenceNo &+ 1
        
        let elapsedMs: UInt32
        if let startTime = sessionStartTime {
            elapsedMs = UInt32(max(0, Date().timeIntervalSince(startTime) * 1000.0))
        } else {
            elapsedMs = 0
        }
        
        let header = PTTFrameHeader(
            type: .chunk,
            sequenceNo: sessionSequenceNo,
            timestampMs: elapsedMs,
            senderHash: mySenderIDHash
        )
        
        // Encode raw PCM to compressed 11.2kbps Opus packet
        let opusPayload = OpusCodecManager.shared.encodePCMToOpus(chunkData)
        
        var packet = header.encode()
        packet.append(opusPayload)
        
        // Broadcast over MultipeerConnectivity stream channel (.unreliable for minimum latency)
        multipeerService.sendRawPTTPacket(packet)
    }
    
    // MARK: - Private Packet Protocols
    
    private func sendPTTPacket(type: PTTFrameType, payload: Data) {
        let elapsedMs: UInt32
        if let startTime = sessionStartTime {
            elapsedMs = UInt32(max(0, Date().timeIntervalSince(startTime) * 1000.0))
        } else {
            elapsedMs = 0
        }
        
        let header = PTTFrameHeader(
            type: type,
            sequenceNo: sessionSequenceNo,
            timestampMs: elapsedMs,
            senderHash: mySenderIDHash
        )
        
        var packet = header.encode()
        packet.append(payload)
        
        multipeerService.sendRawPTTPacket(packet)
    }
    
    private let audioDecodeQueue = DispatchQueue(label: "com.relyvo.audio.decodeQueue", qos: .userInitiated)
    
    private func setupPacketReceiver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIncomingRawPacket(_:)),
            name: .didReceiveRawPTTPacket,
            object: nil
        )
    }
    
    @objc private func handleIncomingRawPacket(_ notification: Notification) {
        guard let packet = notification.userInfo?["packet"] as? Data,
              let header = PTTFrameHeader.decode(from: packet) else { return }
        
        let payload = packet.subdata(in: PTTFrameHeader.headerSize..<packet.count)
        
        audioDecodeQueue.async { [weak self] in
            guard let self = self else { return }
            
            switch header.type {
            case .start:
                DispatchQueue.main.async {
                    self.activeFloorSenderID = "REMOTE_PEER"
                    self.lastReceivedSequenceNo = nil
                    self.lastReceivedTimestampMs = header.timestampMs
                    self.lastArrivalRealTime = Date()
                    self.totalDroppedFramesCount = 0
                    self.totalOutofOrderFramesCount = 0
                }
                
                // Reset Adaptive Jitter Buffer for new PTT session
                AdaptiveJitterBufferManager.shared.resetSession()
                AudioStreamEngine.shared.playConnectChirp()
                AppLogger.multipeer.info("PTT_START received from sender \(header.senderHash)")
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "PTT_START", peer: "REMOTE", details: "senderHash=\(header.senderHash)")
                
            case .chunk:
                guard !self.isFloorLockedBySelf else { return } // Reject echo loops
                
                // Perform Packet Loss Concealment (PLC) if sequence gap is detected
                if let lastSeq = self.lastReceivedSequenceNo {
                    let expectedSeq = lastSeq &+ 1
                    if header.sequenceNo > expectedSeq {
                        let missingCount = min(Int(header.sequenceNo - expectedSeq), 5) // Cap PLC to 5 frames max
                        for offset in 0..<missingCount {
                            let missingSeq = expectedSeq &+ UInt16(offset)
                            let plcPCM = OpusCodecManager.shared.decodePLCFrame()
                            AdaptiveJitterBufferManager.shared.enqueueFrame(
                                sequenceNo: missingSeq,
                                timestampMs: header.timestampMs,
                                pcmData: plcPCM
                            )
                        }
                    }
                }
                
                self.trackPacketLossAndJitter(header: header)
                
                // Decode Opus packet to 20ms raw Int16 PCM frame (off main thread)
                let decodedPCM = OpusCodecManager.shared.decodeOpusToPCM(payload)
                
                // Enqueue frame into WebRTC NetEQ Adaptive Jitter Buffer for 40-60ms pre-buffered playback
                AdaptiveJitterBufferManager.shared.enqueueFrame(
                    sequenceNo: header.sequenceNo,
                    timestampMs: header.timestampMs,
                    pcmData: decodedPCM
                )
                
            case .end:
                DispatchQueue.main.async {
                    self.activeFloorSenderID = nil
                    self.lastReceivedSequenceNo = nil
                }
                
                // Flush remaining buffered frames and stop jitter timer
                AdaptiveJitterBufferManager.shared.flushRemainingSession()
                AudioStreamEngine.shared.playConnectChirp()
                AppLogger.multipeer.info("PTT_END received. Diagnostic Summary - Dropped Frames: \(self.totalDroppedFramesCount), Out-Of-Order: \(self.totalOutofOrderFramesCount)")
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "PTT_END", peer: "REMOTE", details: "dropped=\(self.totalDroppedFramesCount) outOfOrder=\(self.totalOutofOrderFramesCount)")
            }
        }
    }

    
    private func trackPacketLossAndJitter(header: PTTFrameHeader) {
        let now = Date()
        
        if let lastSeq = lastReceivedSequenceNo {
            let expectedSeq = lastSeq &+ 1
            if header.sequenceNo != expectedSeq {
                if header.sequenceNo > lastSeq {
                    let dropped = Int(header.sequenceNo - expectedSeq)
                    totalDroppedFramesCount += dropped
                    AppLogger.multipeer.warning("PTT Frame Loss Detected! Expected seq: \(expectedSeq), Got seq: \(header.sequenceNo) (Missing: \(dropped) frames)")
                } else {
                    totalOutofOrderFramesCount += 1
                    AppLogger.multipeer.warning("PTT Frame Reordering Detected! Got old seq: \(header.sequenceNo), Expected: \(expectedSeq)")
                }
            }
        }
        
        if let lastArrival = lastArrivalRealTime {
            let actualTransitMs = now.timeIntervalSince(lastArrival) * 1000.0
            let expectedTransitMs = Double(header.timestampMs > lastReceivedTimestampMs ? header.timestampMs - lastReceivedTimestampMs : 0)
            let jitterMs = abs(actualTransitMs - expectedTransitMs)
            if jitterMs > 35.0 {
                AppLogger.multipeer.debug("Network Jitter Spike: \(String(format: "%.1f", jitterMs)) ms")
            }
        }
        
        self.lastReceivedSequenceNo = header.sequenceNo
        self.lastReceivedTimestampMs = header.timestampMs
        self.lastArrivalRealTime = now
    }
}

