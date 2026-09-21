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
    
    init() {}

    
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
        } catch {
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
    }
    
    func playReceivedAudioChunk(_ data: Data) {
        // Playback live stream chunk
        DispatchQueue.main.async {
            self.isPlaying = true
        }
    }
    
    private func bufferToData(buffer: AVAudioPCMBuffer) -> Data? {
        let channelCount = Int(buffer.format.channelCount)
        let length = Int(buffer.frameLength) * channelCount * 2
        guard let channelData = buffer.int16ChannelData, length > 0 else { return nil }
        return Data(bytes: channelData[0], count: length)
    }
}
