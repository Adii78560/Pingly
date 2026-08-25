//
//  WalkieTalkieNetworkManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import AVFoundation
import MultipeerConnectivity
import Combine
import os


extension UUID {
    var uuidData: Data {
        var uuid = self.uuid
        return Data(bytes: &uuid, count: 16)
    }
    
    init?(uuidData data: Data) {
        guard data.count >= 16 else { return nil }
        let uuid: uuid_t = data.withUnsafeBytes { $0.load(as: uuid_t.self) }
        self.init(uuid: uuid)
    }
}

func createWavHeader(dataLength: Int, sampleRate: Int32, channels: Int16, bitsPerSample: Int16) -> Data {
    var header = Data()
    header.append("RIFF".data(using: .utf8)!)
    let fileSize = Int32(dataLength + 36)
    var fileSizeLE = fileSize.littleEndian
    header.append(Data(bytes: &fileSizeLE, count: 4))
    header.append("WAVE".data(using: .utf8)!)
    header.append("fmt ".data(using: .utf8)!)
    let fmtSize: Int32 = 16
    var fmtSizeLE = fmtSize.littleEndian
    header.append(Data(bytes: &fmtSizeLE, count: 4))
    let audioFormat: Int16 = 1
    var audioFormatLE = audioFormat.littleEndian
    header.append(Data(bytes: &audioFormatLE, count: 2))
    var numChannelsLE = channels.littleEndian
    header.append(Data(bytes: &numChannelsLE, count: 2))
    var sRateLE = sampleRate.littleEndian
    header.append(Data(bytes: &sRateLE, count: 4))
    let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
    var byteRateLE = byteRate.littleEndian
    header.append(Data(bytes: &byteRateLE, count: 4))
    let blockAlign = channels * (bitsPerSample / 8)
    var blockAlignLE = blockAlign.littleEndian
    header.append(Data(bytes: &blockAlignLE, count: 2))
    var bPerSampleLE = bitsPerSample.littleEndian
    header.append(Data(bytes: &bPerSampleLE, count: 2))
    header.append("data".data(using: .utf8)!)
    var dLengthLE = Int32(dataLength).littleEndian
    header.append(Data(bytes: &dLengthLE, count: 4))
    return header
}

final class AudioRecorderContext {
    let sessionID: UUID
    let fileURL: URL
    private var pcmDataAccumulator = Data()
    private let queue = DispatchQueue(label: "com.pingly.audiorecorder", qos: .utility)
    
    init(sessionID: UUID, fileURL: URL) {
        self.sessionID = sessionID
        self.fileURL = fileURL
    }
    
    func append(pcmData: Data) {
        queue.async {
            self.pcmDataAccumulator.append(pcmData)
        }
    }
    
    func finalize(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            guard !self.pcmDataAccumulator.isEmpty else {
                completion(false)
                return
            }
            
            let sampleRate: Int32 = 16000
            let channels: Int16 = 1
            let bitsPerSample: Int16 = 16
            
            let header = createWavHeader(dataLength: self.pcmDataAccumulator.count, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample)
            
            var wavData = Data()
            wavData.append(header)
            wavData.append(self.pcmDataAccumulator)
            
            do {
                let dir = self.fileURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                try wavData.write(to: self.fileURL)
                completion(true)
            } catch {
                AppLogger.audio.error("Failed to write WAV file: \(error.localizedDescription)")
                completion(false)
            }
        }
    }
}

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
    
    // Active Channel Synced from View Model
    var selectedChannel: String = "CH-1 EMERGENCY"
    
    // PTT Session Tracking (Sender)
    var currentSessionID: UUID? = nil
    private var currentSenderRecorder: AudioRecorderContext? = nil
    
    // PTT Session Tracking (Receiver)
    var currentRemoteSessionID: UUID? = nil
    private var currentReceiverRecorder: AudioRecorderContext? = nil
    private var remoteSessionStartTime: Date? = nil
    private var remoteSessionSenderName: String? = nil
    private var remoteSessionSenderID: String? = nil
    
    // Inactivity Timeout Timer
    private var remoteInactivityWorkItem: DispatchWorkItem?
    
    func getAudioSegmentsDirectory() -> URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupportURL.appendingPathComponent("AudioSegments", isDirectory: true)
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
        
        let sessionID = UUID()
        self.currentSessionID = sessionID
        
        AppLogger.audio.info("[PINGLY_PTT_SESSION] START sessionID=\(sessionID.uuidString) sender=\(NodeIdentity.shared.nodeID)")
        
        let fileURL = getAudioSegmentsDirectory().appendingPathComponent("\(sessionID.uuidString).wav")
        self.currentSenderRecorder = AudioRecorderContext(sessionID: sessionID, fileURL: fileURL)
        
        BackgroundAudioSessionManager.shared.beginBackgroundTask()
        isFloorLockedBySelf = true
        activeFloorSenderID = "LOCAL_SELF"
        sessionSequenceNo = 0
        sessionStartTime = Date()
        
        // Send PTT_START packet to remote peers with sessionID payload
        sendPTTPacket(type: .start, payload: sessionID.uuidData)
        
        // Start live low-latency capture
        let started = AudioStreamEngine.shared.startCapture()
        return started
    }
    
    /// Releases the floor, sends PTT_END frame, and stops microphone recording.
    func releaseFloor(targetPeer: PeerDevice? = nil) {
        guard isFloorLockedBySelf else { return }
        
        AudioStreamEngine.shared.stopCapture()
        
        let sessionID = self.currentSessionID ?? UUID()
        
        // Send PTT_END packet to remote peer with sessionID payload
        sendPTTPacket(type: .end, payload: sessionID.uuidData)
        
        if let recorder = self.currentSenderRecorder {
            let fileURL = recorder.fileURL
            let startTime = self.sessionStartTime ?? Date()
            let duration = Date().timeIntervalSince(startTime)
            let channel = self.selectedChannel
            
            recorder.finalize { success in
                guard success else {
                    AppLogger.audio.error("[PINGLY_AUDIO_PERSIST] FAILURE sessionID=\(sessionID.uuidString) error=file_write_failed")
                    return
                }
                AppLogger.audio.info("[PINGLY_PTT_SESSION] END sessionID=\(sessionID.uuidString) duration=\(duration) file=\(fileURL.path)")
                
                // Save metadata in SwiftData
                DispatchQueue.main.async {
                    _ = SwiftDataService.shared.saveAudioSegment(
                        sessionID: sessionID,
                        senderID: NodeIdentity.shared.nodeID,
                        senderName: NodeIdentity.shared.displayName,
                        channelID: channel,
                        duration: duration,
                        localFileURL: fileURL.path,
                        directionRaw: "SENDER"
                    )
                }
            }
        }
        
        isFloorLockedBySelf = false
        activeFloorSenderID = nil
        sessionStartTime = nil
        self.currentSenderRecorder = nil
        self.currentSessionID = nil
        BackgroundAudioSessionManager.shared.endBackgroundTask()
    }
    
    /// Hard-stops all in-flight audio on both transmit and receive sides immediately.
    ///
    /// Called when the user switches channels so that audio from the previous channel
    /// does not bleed into the newly selected one. Unlike `releaseFloor()`, this method
    /// does not require the device to own the floor lock — it terminates any active
    /// remote session as well and immediately silences the player node.
    func stopActiveAudioStream() {
        AppLogger.audio.info("[ChannelSwitch] Stopping all active audio streams before channel switch")
        
        // Stop transmit side if we are currently holding the floor
        if isFloorLockedBySelf {
            AudioStreamEngine.shared.stopCapture()
            let sessionID = self.currentSessionID ?? UUID()
            sendPTTPacket(type: .end, payload: sessionID.uuidData)
            isFloorLockedBySelf = false
            sessionStartTime = nil
            currentSenderRecorder = nil
            currentSessionID = nil
            BackgroundAudioSessionManager.shared.endBackgroundTask()
            AppLogger.audio.info("[ChannelSwitch] TX floor released during channel switch")
        }
        
        // Stop receive side: cancel inactivity timer, finalize remote recorder, silence player
        remoteInactivityWorkItem?.cancel()
        remoteInactivityWorkItem = nil
        
        if currentRemoteSessionID != nil {
            finalizeRemotePTTSession(actualSessionID: nil)
            AppLogger.audio.info("[ChannelSwitch] RX remote session finalized during channel switch")
        }
        
        // Immediately stop playback queue and reset floor publisher state
        AudioStreamEngine.shared.playerNode.stop()
        
        DispatchQueue.main.async {
            self.activeFloorSenderID = nil
            self.lastReceivedSequenceNo = nil
        }
        
        AppLogger.audio.info("[ChannelSwitch] Audio stream fully stopped; player node flushed")
    }
    
    // MARK: - Audio Stream Delegate
    
    func audioStreamEngine(_ engine: AudioStreamEngine, didCaptureAudioChunk chunkData: Data) {
        guard isFloorLockedBySelf else { return }
        
        // Record captured microphone raw PCM
        currentSenderRecorder?.append(pcmData: chunkData)
        
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
    
    private var currentPTTStartTimestamp: Date? = nil
    private var currentPTTRxFrames: Int = 0
    private var firstPacketLogged: Bool = false
    
    private func setupPacketReceiver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIncomingRawPacket(_:)),
            name: .didReceiveRawPTTPacket,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioPlayed(_:)),
            name: .audioStreamEngineDidPlayAudioChunk,
            object: nil
        )
    }
    
    @objc private func handleAudioPlayed(_ notification: Notification) {
        guard let data = notification.userInfo?["data"] as? Data else { return }
        audioDecodeQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentReceiverRecorder?.append(pcmData: data)
        }
    }
    
    private func resetRemoteInactivityTimer() {
        remoteInactivityWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.currentRemoteSessionID != nil {
                AppLogger.audio.warning("PTT Remote Session Inactivity Timeout! Finalizing session.")
                self.finalizeRemotePTTSession(actualSessionID: nil)
            }
        }
        
        remoteInactivityWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }
    
    private func finalizeRemotePTTSession(actualSessionID: UUID?) {
        remoteInactivityWorkItem?.cancel()
        remoteInactivityWorkItem = nil
        
        guard let recorder = self.currentReceiverRecorder else { return }
        self.currentReceiverRecorder = nil
        
        let sessionID = actualSessionID ?? recorder.sessionID
        let fileURL = recorder.fileURL
        let startTime = self.remoteSessionStartTime ?? Date()
        let duration = Date().timeIntervalSince(startTime)
        let senderName = self.remoteSessionSenderName ?? "Unknown"
        let senderID = self.remoteSessionSenderID ?? "Unknown"
        let channel = self.selectedChannel
        
        recorder.finalize { success in
            guard success else {
                AppLogger.audio.error("[PINGLY_AUDIO_PERSIST] FAILURE sessionID=\(sessionID.uuidString) error=file_write_failed")
                return
            }
            AppLogger.audio.info("[PINGLY_PTT_RECEIVE] END sessionID=\(sessionID.uuidString) duration=\(duration) file=\(fileURL.path)")
            
            // Save metadata in SwiftData
            DispatchQueue.main.async {
                _ = SwiftDataService.shared.saveAudioSegment(
                    sessionID: sessionID,
                    senderID: senderID,
                    senderName: senderName,
                    channelID: channel,
                    duration: duration,
                    localFileURL: fileURL.path,
                    directionRaw: "RECEIVER"
                )
            }
        }
        
        self.currentRemoteSessionID = nil
        self.remoteSessionStartTime = nil
        self.remoteSessionSenderName = nil
        self.remoteSessionSenderID = nil
        
        DispatchQueue.main.async {
            self.activeFloorSenderID = nil
            self.lastReceivedSequenceNo = nil
        }
    }
    
    @objc private func handleIncomingRawPacket(_ notification: Notification) {
        guard let packet = notification.userInfo?["packet"] as? Data,
              let header = PTTFrameHeader.decode(from: packet) else { return }
        
        let payload = packet.subdata(in: PTTFrameHeader.headerSize..<packet.count)
        
        audioDecodeQueue.async { [weak self] in
            guard let self = self else { return }
            
            switch header.type {
            case .start:
                let sessionID = UUID(uuidData: payload) ?? UUID()
                self.currentRemoteSessionID = sessionID
                self.remoteSessionStartTime = Date()
                
                let peerID = notification.userInfo?["peerID"] as? MCPeerID
                let senderDisplayName = peerID?.displayName ?? "Remote Speaker"
                self.remoteSessionSenderName = senderDisplayName
                self.remoteSessionSenderID = peerID?.displayName ?? "Remote Node"
                
                AppLogger.audio.info("[PINGLY_PTT_RECEIVE] START sessionID=\(sessionID.uuidString) sender=\(self.remoteSessionSenderID ?? "")")
                
                let fileURL = self.getAudioSegmentsDirectory().appendingPathComponent("\(sessionID.uuidString).wav")
                self.currentReceiverRecorder = AudioRecorderContext(sessionID: sessionID, fileURL: fileURL)
                
                self.currentPTTStartTimestamp = Date()
                self.currentPTTRxFrames = 0
                self.firstPacketLogged = false
                
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
                AppLogger.multipeer.info("PTT_START received from sender \(header.senderHash) with sessionID \(sessionID.uuidString)")
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "PTT_START", peer: "REMOTE", details: "senderHash=\(header.senderHash)")
                RelaynTransportDiagnosticsManager.shared.incrementPhysicalTestPTTSessions()
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "PTTFunnel", event: "PTT_TEST_BEGIN", peer: "REMOTE")
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "PTTFunnel", event: "PTT_START", peer: "REMOTE", details: "senderHash=\(header.senderHash)")
                
                self.resetRemoteInactivityTimer()
                
            case .chunk:
                guard !self.isFloorLockedBySelf else { return } // Reject echo loops
                
                guard self.currentRemoteSessionID != nil else {
                    // Log orphan chunk frames without active sessionID and safely discard/skip processing
                    AppLogger.multipeer.warning("[PINGLY_PTT_RECEIVE] ORPHAN CHUNK sessionID=nil seq=\(header.sequenceNo) sender=\(header.senderHash)")
                    return
                }
                
                self.resetRemoteInactivityTimer()
                
                if header.sequenceNo % 50 == 0 {
                    AppLogger.audio.info("[PINGLY_PTT_SESSION] FRAME sessionID=\(self.currentRemoteSessionID?.uuidString ?? "") seq=\(header.sequenceNo)")
                }
                
                self.currentPTTRxFrames += 1
                RelaynTransportDiagnosticsManager.shared.addPhysicalTestPTTRxFrames(count: 1)
                
                if !self.firstPacketLogged {
                    self.firstPacketLogged = true
                    let latencyMs = self.currentPTTStartTimestamp != nil ? Int(Date().timeIntervalSince(self.currentPTTStartTimestamp!) * 1000) : 0
                    RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "PTTFunnel", event: "PTT_FIRST_PACKET", peer: "REMOTE", details: "latencyMs=\(latencyMs)")
                }
                
                if self.currentPTTRxFrames % 100 == 0 {
                    let durationMs = self.currentPTTStartTimestamp != nil ? Int(Date().timeIntervalSince(self.currentPTTStartTimestamp!) * 1000) : 0
                    RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "PTTFunnel", event: "PTT_PROGRESS", peer: "REMOTE", details: "durationMs=\(durationMs) rxFrames=\(self.currentPTTRxFrames) droppedFrames=\(self.totalDroppedFramesCount)")
                }
                
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
                let durationMs = self.currentPTTStartTimestamp != nil ? Int(Date().timeIntervalSince(self.currentPTTStartTimestamp!) * 1000) : 0
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "PTTFunnel", event: "PTT_END", peer: "REMOTE", details: "durationMs=\(durationMs) totalRxFrames=\(self.currentPTTRxFrames) droppedFrames=\(self.totalDroppedFramesCount)")
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "PTTFunnel", event: "PTT_TEST_RESULT", peer: "REMOTE", details: "result=COMPLETED sessionState=CONNECTED")
                
                let endSessionID = UUID(uuidData: payload) ?? self.currentRemoteSessionID
                
                // Flush remaining buffered frames and stop jitter timer
                AdaptiveJitterBufferManager.shared.flushRemainingSession()
                AudioStreamEngine.shared.playConnectChirp()
                AppLogger.multipeer.info("PTT_END received. Diagnostic Summary - Dropped Frames: \(self.totalDroppedFramesCount), Out-Of-Order: \(self.totalOutofOrderFramesCount)")
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "PTT_END", peer: "REMOTE", details: "dropped=\(self.totalDroppedFramesCount) outOfOrder=\(self.totalOutofOrderFramesCount)")
                
                self.finalizeRemotePTTSession(actualSessionID: endSessionID)
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

