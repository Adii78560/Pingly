//
//  WalkieTalkieNetworkManager.swift
//  Pingly
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

/// Floor control network manager implementing half-duplex state machine and binary framing protocol.
final class WalkieTalkieNetworkManager: NSObject, ObservableObject, AudioStreamEngineDelegate {
    
    static let shared = WalkieTalkieNetworkManager()
    
    @Published var activeFloorSenderID: String? = nil
    @Published var isFloorLockedBySelf: Bool = false
    
    private var multipeerService: MultipeerService {
        return MultipeerService.shared
    }
    
    private var sequenceNumber: UInt32 = 0
    private let mySenderIDHash: UInt32 = UInt32(truncatingIfNeeded: Locale.current.identifier.hashValue)
    
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
        sequenceNumber = 0
        
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
        BackgroundAudioSessionManager.shared.endBackgroundTask()
    }
    
    // MARK: - Audio Stream Delegate
    
    func audioStreamEngine(_ engine: AudioStreamEngine, didCaptureAudioChunk chunkData: Data) {
        guard isFloorLockedBySelf else { return }
        sequenceNumber += 1
        
        // Construct binary packet: [1 Byte Type] + [4 Byte Seq] + [4 Byte Sender] + [Audio Bytes]
        var packet = Data()
        var typeByte = PTTFrameType.chunk.rawValue
        var seqBE = sequenceNumber.bigEndian
        var senderBE = mySenderIDHash.bigEndian
        
        packet.append(&typeByte, count: 1)
        packet.append(Data(bytes: &seqBE, count: 4))
        packet.append(Data(bytes: &senderBE, count: 4))
        packet.append(chunkData)
        
        // Broadcast over MultipeerConnectivity stream channel (.unreliable for minimum latency)
        multipeerService.sendRawPTTPacket(packet)
    }
    
    // MARK: - Private Packet Protocols
    
    private func sendPTTPacket(type: PTTFrameType, payload: Data) {
        var packet = Data()
        var typeByte = type.rawValue
        var seqBE = sequenceNumber.bigEndian
        var senderBE = mySenderIDHash.bigEndian
        
        packet.append(&typeByte, count: 1)
        packet.append(Data(bytes: &seqBE, count: 4))
        packet.append(Data(bytes: &senderBE, count: 4))
        packet.append(payload)
        
        multipeerService.sendRawPTTPacket(packet)
    }
    
    private func setupPacketReceiver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIncomingRawPacket(_:)),
            name: .didReceiveRawPTTPacket,
            object: nil
        )
    }
    
    @objc private func handleIncomingRawPacket(_ notification: Notification) {
        guard let packet = notification.userInfo?["packet"] as? Data, packet.count >= 9 else { return }
        
        let typeRaw = packet[0]
        guard let frameType = PTTFrameType(rawValue: typeRaw) else { return }
        
        let payload = packet.subdata(in: 9..<packet.count)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch frameType {
            case .start:
                self.activeFloorSenderID = "REMOTE_PEER"
                AudioStreamEngine.shared.playConnectChirp()
                
            case .chunk:
                guard !self.isFloorLockedBySelf else { return } // Reject echo loops
                AudioStreamEngine.shared.playAudioChunk(payload)
                
            case .end:
                self.activeFloorSenderID = nil
                AudioStreamEngine.shared.playConnectChirp()
            }
        }
    }
}
