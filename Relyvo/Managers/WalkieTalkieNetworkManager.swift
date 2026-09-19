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
        withUnsafeBytes(of: self.uuid) { Data($0) }
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
    var fileSizeLE = Int32(dataLength + 36).littleEndian
    withUnsafeBytes(of: fileSizeLE) { header.append(contentsOf: $0) }
    header.append("WAVE".data(using: .utf8)!)
    header.append("fmt ".data(using: .utf8)!)
    var fmtSizeLE = Int32(16).littleEndian
    withUnsafeBytes(of: fmtSizeLE) { header.append(contentsOf: $0) }
    var audioFormatLE = Int16(1).littleEndian
    withUnsafeBytes(of: audioFormatLE) { header.append(contentsOf: $0) }
    var numChannelsLE = channels.littleEndian
    withUnsafeBytes(of: numChannelsLE) { header.append(contentsOf: $0) }
    var sRateLE = sampleRate.littleEndian
    withUnsafeBytes(of: sRateLE) { header.append(contentsOf: $0) }
    var byteRateLE = (sampleRate * Int32(channels) * Int32(bitsPerSample / 8)).littleEndian
    withUnsafeBytes(of: byteRateLE) { header.append(contentsOf: $0) }
    var blockAlignLE = (channels * (bitsPerSample / 8)).littleEndian
    withUnsafeBytes(of: blockAlignLE) { header.append(contentsOf: $0) }
    var bPerSampleLE = bitsPerSample.littleEndian
    withUnsafeBytes(of: bPerSampleLE) { header.append(contentsOf: $0) }
    header.append("data".data(using: .utf8)!)
    var dLengthLE = Int32(dataLength).littleEndian
    withUnsafeBytes(of: dLengthLE) { header.append(contentsOf: $0) }
    return header
}

final class AudioRecorderContext {
    let sessionID: UUID
    let fileURL: URL
    private var audioFile: AVAudioFile?
    private var pcmDataAccumulator = Data()
    private var writtenFrames: AVAudioFramePosition = 0
    private let queue = DispatchQueue(label: "com.pingly.audiorecorder", qos: .utility)
    
    private let pcmFormat: AVAudioFormat? = {
        return AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: true
        )
    }()
    
    init(sessionID: UUID, fileURL: URL) {
        self.sessionID = sessionID
        self.fileURL = fileURL
        
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        do {
            self.audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            AppLogger.audio.info("[AUDIO_RECORDER] Opened AVAudioFile for stream writing: \(fileURL.lastPathComponent)")
        } catch {
            AppLogger.audio.warning("[AUDIO_RECORDER] AVAudioFile init fallback: \(error.localizedDescription)")
        }
    }
    
    func append(pcmData: Data) {
        guard !pcmData.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pcmDataAccumulator.append(pcmData)
            
            guard let format = self.pcmFormat, let file = self.audioFile else { return }
            let frameCount = AVAudioFrameCount(pcmData.count / 2) // 16-bit mono = 2 bytes per frame
            guard frameCount > 0, let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            
            pcmBuffer.frameLength = frameCount
            pcmData.withUnsafeBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress, let channelData = pcmBuffer.int16ChannelData?[0] {
                    memcpy(channelData, baseAddress, pcmData.count)
                }
            }
            
            do {
                try file.write(from: pcmBuffer)
                self.writtenFrames += AVAudioFramePosition(frameCount)
            } catch {
                AppLogger.audio.error("[AUDIO_RECORDER] Write chunk error: \(error.localizedDescription)")
            }
        }
    }
    
    func finalize(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            
            // Release open AVAudioFile handle
            self.audioFile = nil
            
            guard !self.pcmDataAccumulator.isEmpty else {
                AppLogger.audio.warning("[AUDIO_RECORDER] Finalize rejected — zero PCM bytes captured")
                completion(false)
                return
            }
            
            // Validate file on disk; if AVAudioFile wrote valid frames, succeed immediately
            if self.writtenFrames > 0 && FileManager.default.fileExists(atPath: self.fileURL.path) {
                AppLogger.audio.info("[AUDIO_RECORDER] Finalized AVAudioFile successfully (\(self.writtenFrames) frames)")
                completion(true)
                return
            }
            
            // Fallback WAV header writer to guarantee zero data loss
            let sampleRate: Int32 = 16000
            let channels: Int16 = 1
            let bitsPerSample: Int16 = 16
            
            let header = createWavHeader(dataLength: self.pcmDataAccumulator.count, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample)
            var wavData = Data()
            wavData.append(header)
            wavData.append(self.pcmDataAccumulator)
            
            do {
                try wavData.write(to: self.fileURL)
                AppLogger.audio.info("[AUDIO_RECORDER] Finalized fallback WAV file successfully (\(wavData.count) bytes)")
                completion(true)
            } catch {
                AppLogger.audio.error("[AUDIO_RECORDER] Failed to finalize audio file: \(error.localizedDescription)")
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

/// Extended 41-Byte PTT Binary Header
/// Format: [1 Byte Type] + [1 Byte HopCount] + [1 Byte TTL] + [2 Bytes SequenceNo] + [4 Bytes TimestampMs] + [16 Bytes SenderNodeID] + [16 Bytes SessionID]
struct PTTFrameHeader {
    let type: PTTFrameType   // 1 Byte
    let hopCount: UInt8      // 1 Byte
    let ttl: UInt8           // 1 Byte
    let sequenceNo: UInt16   // 2 Bytes (wraps at 65535)
    let timestampMs: UInt32  // 4 Bytes (ms elapsed since PTT_START)
    let senderNodeID: UUID   // 16 Bytes
    let sessionID: UUID      // 16 Bytes
    
    static let headerSize: Int = 41
    
    func encode() -> Data {
        var data = Data(capacity: PTTFrameHeader.headerSize)
        data.append(type.rawValue)
        data.append(hopCount)
        data.append(ttl)
        
        let seqBE = sequenceNo.bigEndian
        withUnsafeBytes(of: seqBE) { data.append(contentsOf: $0) }
        
        let timeBE = timestampMs.bigEndian
        withUnsafeBytes(of: timeBE) { data.append(contentsOf: $0) }
        
        let senderUUIDBytes = withUnsafeBytes(of: senderNodeID.uuid) { Data($0) }
        data.append(senderUUIDBytes)
        
        let sessionUUIDBytes = withUnsafeBytes(of: sessionID.uuid) { Data($0) }
        data.append(sessionUUIDBytes)
        
        return data
    }
    
    static func decode(from data: Data) -> PTTFrameHeader? {
        guard data.count >= PTTFrameHeader.headerSize else { return nil }
        let typeRaw = data[0]
        guard let frameType = PTTFrameType(rawValue: typeRaw) else { return nil }
        
        let hopCount = data[1]
        let ttl = data[2]
        
        let seqBE = data.subdata(in: 3..<5).withUnsafeBytes { $0.load(as: UInt16.self) }
        let timeBE = data.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: UInt32.self) }
        
        let senderUUIDBytes = data.subdata(in: 9..<25)
        let senderUUID = senderUUIDBytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
        
        let sessionUUIDBytes = data.subdata(in: 25..<41)
        let sessionUUID = sessionUUIDBytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
        
        return PTTFrameHeader(
            type: frameType,
            hopCount: hopCount,
            ttl: ttl,
            sequenceNo: UInt16(bigEndian: seqBE),
            timestampMs: UInt32(bigEndian: timeBE),
            senderNodeID: UUID(uuid: senderUUID),
            sessionID: UUID(uuid: sessionUUID)
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
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("VoiceNotes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
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
            let alias = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? NodeIdentity.shared.displayName
            
            recorder.finalize { success in
                guard success else {
                    AppLogger.audio.error("[PINGLY_AUDIO_PERSIST] FAILURE sessionID=\(sessionID.uuidString) error=file_write_failed")
                    return
                }
                AppLogger.audio.info("[PINGLY_AUDIO_PERSIST] SUCCESS sessionID=\(sessionID.uuidString) duration=\(duration) file=\(fileURL.path)")
                AppLogger.audio.info("[PINGLY_PTT_SESSION] END sessionID=\(sessionID.uuidString) duration=\(duration) file=\(fileURL.path)")
                
                // Save Voice Message in SwiftData
                Task {
                    let m4aPath = VoiceStorageManager.shared.voiceNotesDirectory.appendingPathComponent("\(sessionID.uuidString).m4a").path
                    await SwiftDataService.shared.persistenceActor.saveVoiceMessage(
                        sessionID: sessionID,
                        channelID: channel,
                        senderID: NodeIdentity.shared.nodeID,
                        senderAlias: alias,
                        timestamp: startTime,
                        duration: duration,
                        audioFilePath: m4aPath,
                        directionRaw: "SENDER",
                        isDelivered: true
                    )
                    
                    // Asynchronously compress intermediate WAV to M4A container
                    VoiceStorageManager.shared.compressWAVToM4A(wavURL: fileURL, sessionID: sessionID)
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
        
        let senderUUID = UUID(uuidString: NodeIdentity.shared.nodeID) ?? UUID()
        let sessionUUID = currentSessionID ?? UUID() // Fallback, though currentSessionID should be set

        let header = PTTFrameHeader(
            type: .chunk,
            hopCount: 0,
            ttl: 3,
            sequenceNo: sessionSequenceNo,
            timestampMs: elapsedMs,
            senderNodeID: senderUUID,
            sessionID: sessionUUID
        )
        
        // Encode raw PCM to compressed 11.2kbps Opus packet
        let opusPayload = OpusCodecManager.shared.encodePCMToOpus(chunkData)
        
        var packet = header.encode()
        packet.append(opusPayload)
        
        // Broadcast over MultipeerConnectivity stream channel (.unreliable for minimum latency)
        multipeerService.sendRawPTTPacket(packet, type: .chunk)
    }
    
    // MARK: - Private Packet Protocols
    
    private func sendPTTPacket(type: PTTFrameType, payload: Data) {
        let elapsedMs: UInt32
        if let startTime = sessionStartTime {
            elapsedMs = UInt32(max(0, Date().timeIntervalSince(startTime) * 1000.0))
        } else {
            elapsedMs = 0
        }
        
        let senderUUID = UUID(uuidString: NodeIdentity.shared.nodeID) ?? UUID()
        let sessionUUID = currentSessionID ?? UUID()
        
        let header = PTTFrameHeader(
            type: type,
            hopCount: 0,
            ttl: 3,
            sequenceNo: sessionSequenceNo,
            timestampMs: elapsedMs,
            senderNodeID: senderUUID,
            sessionID: sessionUUID
        )
        
        var packet = header.encode()
        packet.append(payload)
        
        multipeerService.sendRawPTTPacket(packet, type: type)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIncomingSOS(_:)),
            name: .didReceiveEmergencySOS,
            object: nil
        )
    }
    
    @objc func handleIncomingSOS(_ notification: Notification) {
        audioDecodeQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.isFloorLockedBySelf {
                AppLogger.multipeer.warning("[FLOOR_PREEMPTED_BY_SOS] Forcibly revoking local PTT floor lock due to emergency SOS beacon")
                DispatchQueue.main.async {
                    self.releaseFloor()
                }
            }
            
            // Trigger emergency tactical alert tone and haptic vibration
            AudioServicesPlaySystemSound(1005)
            HapticManager.errorFeedback()
            AppLogger.multipeer.warning("[SOS_ALERT_SOUND_PLAYED] High-priority SOS audio alarm dispatched")
        }
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
            AppLogger.audio.info("[PINGLY_AUDIO_PERSIST] SUCCESS sessionID=\(sessionID.uuidString) duration=\(duration) file=\(fileURL.path)")
            AppLogger.audio.info("[PINGLY_PTT_RECEIVE] END sessionID=\(sessionID.uuidString) duration=\(duration) file=\(fileURL.path)")
            
            // Save Voice Message in SwiftData
            Task {
                let m4aPath = VoiceStorageManager.shared.voiceNotesDirectory.appendingPathComponent("\(sessionID.uuidString).m4a").path
                await SwiftDataService.shared.persistenceActor.saveVoiceMessage(
                    sessionID: sessionID,
                    channelID: channel,
                    senderID: senderID,
                    senderAlias: senderName,
                    timestamp: startTime,
                    duration: duration,
                    audioFilePath: m4aPath,
                    directionRaw: "RECEIVER",
                    isDelivered: true
                )
                
                // Asynchronously compress intermediate WAV to M4A container
                VoiceStorageManager.shared.compressWAVToM4A(wavURL: fileURL, sessionID: sessionID)
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
    /// Explicit EOT handler to instantly tear down playback and release floor locks without waiting for timeouts.
    func handleExplicitEOT() {
        audioDecodeQueue.async { [weak self] in
            guard let self = self else { return }
            AppLogger.audio.info("[EOT_TEARDOWN] Explicit EOT signal executed — terminating remote playback & locks")
            self.remoteInactivityWorkItem?.cancel()
            self.remoteInactivityWorkItem = nil
            AudioStreamEngine.shared.playerNode.stop()
            AdaptiveJitterBufferManager.shared.flushRemainingSession()
            AudioStreamEngine.shared.resetSequenceTracker()
            AudioStreamEngine.shared.playConnectChirp()
            self.finalizeRemotePTTSession(actualSessionID: nil)
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
                // Deterministic PTT Floor Arbitration (Collision Resolution)
                if self.isFloorLockedBySelf {
                    let localNodeID = NodeIdentity.shared.nodeID
                    let remoteNodeID = header.senderNodeID.uuidString
                    
                    if localNodeID <= remoteNodeID {
                        // Local node wins tie-breaker (lexicographically smaller UUID/ID)
                        AppLogger.multipeer.warning("[FLOOR_COLLISION_RESOLVED] winner=\(localNodeID) loser=\(remoteNodeID) channel=\(self.selectedChannel)")
                        return
                    } else {
                        // Remote node wins tie-breaker (local yields floor immediately)
                        AppLogger.multipeer.warning("[FLOOR_COLLISION_RESOLVED] winner=\(remoteNodeID) loser=\(localNodeID) channel=\(self.selectedChannel)")
                        AudioStreamEngine.shared.stopCapture()
                        self.isFloorLockedBySelf = false
                        self.sessionStartTime = nil
                        self.currentSenderRecorder = nil
                        self.currentSessionID = nil
                        BackgroundAudioSessionManager.shared.endBackgroundTask()
                    }
                }
                
                let sessionID = header.sessionID
                self.currentRemoteSessionID = sessionID
                self.remoteSessionStartTime = Date()
                
                let peerID = notification.userInfo?["peerID"] as? MCPeerID
                let senderDisplayName = peerID?.displayName ?? "Remote Speaker"
                self.remoteSessionSenderName = senderDisplayName
                self.remoteSessionSenderID = header.senderNodeID.uuidString
                
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
                
                // Reset Adaptive Jitter Buffer & Sequence Tracker for new PTT session
                AdaptiveJitterBufferManager.shared.resetSession()
                AudioStreamEngine.shared.resetSequenceTracker()
                AudioStreamEngine.shared.playConnectChirp()
                AppLogger.multipeer.info("PTT_START received from sender \(header.senderNodeID.uuidString.prefix(8)) with sessionID \(sessionID.uuidString)")
                RelaynTransportDiagnosticsManager.shared.recordLifecycleEvent(event: "PTT_START", peer: "REMOTE", details: "senderNodeID=\(header.senderNodeID.uuidString.prefix(8))")
                RelaynTransportDiagnosticsManager.shared.incrementPhysicalTestPTTSessions()
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "PTTFunnel", event: "PTT_TEST_BEGIN", peer: "REMOTE")
                RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "PTTFunnel", event: "PTT_START", peer: "REMOTE", details: "senderNodeID=\(header.senderNodeID.uuidString.prefix(8))")
                
                self.resetRemoteInactivityTimer()
                
            case .chunk:
                guard !self.isFloorLockedBySelf else { return } // Reject echo loops
                
                guard self.currentRemoteSessionID != nil else {
                    // Log orphan chunk frames without active sessionID and safely discard/skip processing
                    AppLogger.multipeer.warning("[PINGLY_PTT_RECEIVE] ORPHAN CHUNK sessionID=nil seq=\(header.sequenceNo) sender=\(header.senderNodeID.uuidString.prefix(8))")
                    return
                }
                
                guard header.sessionID == self.currentRemoteSessionID, header.senderNodeID.uuidString == self.remoteSessionSenderID else {
                    AppLogger.multipeer.warning("[PINGLY_PTT_RECEIVE] MISMATCHED CHUNK sessionID=\(header.sessionID.uuidString) expected=\(self.currentRemoteSessionID?.uuidString ?? "nil")")
                    return
                }
                
                // Audio Packet Sequencing & Jitter Reordering Check (accounting for UInt16 wraparound)
                if let lastSeq = self.lastReceivedSequenceNo {
                    let diff = Int16(bitPattern: header.sequenceNo &- lastSeq)
                    if diff <= 0 {
                        AppLogger.audio.warning("[AUDIO_JITTER_DROP] seq=\(header.sequenceNo) expected>=\(lastSeq)")
                        return
                    }
                }
                self.lastReceivedSequenceNo = header.sequenceNo
                
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
                
                let endSessionID = header.sessionID
                
                // Do not allow an old session's END packet to terminate a newer session
                if let currentRemote = self.currentRemoteSessionID, currentRemote != endSessionID {
                    AppLogger.multipeer.warning("[PINGLY_PTT_RECEIVE] END ignored for old/mismatched session: \(endSessionID.uuidString)")
                    return
                }
                
                // Explicit Stream Teardown (EOT): flush remaining buffered frames and cancel inactivity timer immediately
                AppLogger.audio.info("[EOT_TEARDOWN] Explicit End-of-Transmission received for session=\(endSessionID.uuidString)")
                self.remoteInactivityWorkItem?.cancel()
                self.remoteInactivityWorkItem = nil
                AdaptiveJitterBufferManager.shared.flushRemainingSession()
                AudioStreamEngine.shared.resetSequenceTracker()
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

