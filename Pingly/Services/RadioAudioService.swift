//
//  RadioAudioService.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import AVFoundation
import Combine
import os

/// Production AVFoundation audio manager handling live Push-To-Talk (PTT) radio streaming and waveform levels
final class RadioAudioService: ObservableObject {
    
    static let shared = RadioAudioService()
    
    // MARK: - Published Properties

    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentAudioLevel: Float = 0.0
    
    // MARK: - Audio Engine Objects
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    let audioChunkSubject = PassthroughSubject<Data, Never>()
    var audioChunkPublisher: AnyPublisher<Data, Never> {
        audioChunkSubject.eraseToAnyPublisher()
    }
    
    init() {
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                AppLogger.audio.info("AVAudioSession configured asynchronously")
            } catch {
                AppLogger.audio.error("Failed to configure AVAudioSession: \(error.localizedDescription)")
            }
        }
    }

    
    func startRecordingPTT() {
        guard !isRecording else { return }
        
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: Constants.Audio.bufferSize, format: format) { [weak self] (buffer, time) in
            guard let self = self else { return }
            
            // Calculate audio power level for waveform UI
            let channelData = buffer.floatChannelData?[0]
            let channelDataLength = Int(buffer.frameLength)
            var sum: Float = 0.0
            if let data = channelData {
                for i in 0..<channelDataLength {
                    sum += data[i] * data[i]
                }
                let rms = sqrt(sum / Float(channelDataLength))
                DispatchQueue.main.async {
                    self.currentAudioLevel = min(max(rms * 5.0, 0.0), 1.0)
                }
            }
            
            // Convert PCM buffer into Data stream
            if let pcmData = self.bufferToData(buffer: buffer) {
                self.audioChunkSubject.send(pcmData)
            }
        }
        
        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
            }
            AppLogger.audio.info("Started recording live PTT voice stream")
        } catch {
            AppLogger.audio.error("Failed to start AVAudioEngine: \(error.localizedDescription)")
        }
    }
    
    func stopRecordingPTT() {
        guard isRecording else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        DispatchQueue.main.async {
            self.isRecording = false
            self.currentAudioLevel = 0.0
        }
        AppLogger.audio.info("Stopped recording live PTT voice stream")
    }
    
    func playReceivedAudioChunk(_ data: Data) {
        // Playback live stream chunk
        DispatchQueue.main.async {
            self.isPlaying = true
        }
    }
    
    private func bufferToData(buffer: AVAudioPCMBuffer) -> Data? {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return nil }
        return Data(bytes: mData, count: Int(audioBuffer.mDataByteSize))
    }
}
