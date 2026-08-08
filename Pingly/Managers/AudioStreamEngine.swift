//
//  AudioStreamEngine.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import AVFoundation
import AudioToolbox
import Combine
import os

protocol AudioStreamEngineDelegate: AnyObject {
    func audioStreamEngine(_ engine: AudioStreamEngine, didCaptureAudioChunk chunkData: Data)
}

/// Real-time low-latency audio capture & player engine using AVAudioEngine with bandpass radio filter and voice processing.
final class AudioStreamEngine: NSObject, ObservableObject {
    
    static let shared = AudioStreamEngine()
    weak var delegate: AudioStreamEngineDelegate?
    
    @Published private(set) var currentAudioLevel: Float = 0.0
    
    // Core Engine Nodes
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let bandpassEQ = AVAudioUnitEQ(numberOfBands: 2)
    
    private(set) var isRecording = false
    private let audioQueue = DispatchQueue(label: "com.pingly.audiostream", qos: .userInteractive)
    
    private override init() {
        super.init()
        setupEngineNodes()
    }
    
    // MARK: - Setup Engine Architecture
    
    private func setupEngineNodes() {
        // Enable Voice Processing (Voice Isolation, Acoustic Echo Cancellation, Noise Suppression)
        do {
            try audioEngine.inputNode.setVoiceProcessingEnabled(true)
            AppLogger.audio.info("Hardware Voice Processing & Noise Suppression enabled")
        } catch {
            AppLogger.audio.warning("Could not enable Voice Processing: \(error.localizedDescription)")
        }
        
        // Bandpass Filter Setup (Radio Transceiver Audio Simulation: 300Hz to 3400Hz)
        let hpFilter = bandpassEQ.bands[0]
        hpFilter.filterType = .highPass
        hpFilter.frequency = 300.0 // Cut low rumbles
        hpFilter.bypass = false
        
        let lpFilter = bandpassEQ.bands[1]
        lpFilter.filterType = .lowPass
        lpFilter.frequency = 3400.0 // Cut high noise
        lpFilter.bypass = false
        
        // Attach nodes to engine
        audioEngine.attach(playerNode)
        audioEngine.attach(bandpassEQ)
        
        // Connect player pipeline: Player -> EQ -> MainMixer
        let format = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        audioEngine.connect(playerNode, to: bandpassEQ, format: format)
        audioEngine.connect(bandpassEQ, to: audioEngine.mainMixerNode, format: format)
    }
    
    // MARK: - Public Recording Engine
    
    /// Starts capturing live microphone audio buffer chunks (20ms frames).
    func startCapture() -> Bool {
        BackgroundAudioSessionManager.shared.configureAudioSession()
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        // Target 16kHz mono format for P2P network stream efficiency
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            return false
        }
        
        guard let formatConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return false
        }
        
        // 16kHz * 0.02 sec = 320 samples per 20ms chunk
        let bufferSize = AVAudioFrameCount(320)
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self, self.isRecording else { return }
            
            // Direct float buffer RMS level calculation with logarithmic compression
            if let floatChannelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                if frameLength > 0 {
                    var sum: Float = 0.0
                    for i in 0..<frameLength {
                        let sample = floatChannelData[i]
                        sum += sample * sample
                    }
                    let rms = sqrt(sum / Float(frameLength))
                    let boostedLevel = min(max(sqrt(rms) * 2.8, 0.0), 1.0)
                    DispatchQueue.main.async {
                        self.currentAudioLevel = boostedLevel
                    }
                }
            }
            
            // Forward buffer to live speech transcriber
            SpeechTranscriberManager.shared.processAudioBuffer(buffer)
            
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize) else { return }
            var error: NSError?
            
            let status = formatConverter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            if status == .haveData, let data = self.pcmBufferToData(convertedBuffer) {
                self.delegate?.audioStreamEngine(self, didCaptureAudioChunk: data)
            }
        }


        
        do {
            try audioEngine.start()
            isRecording = true
            AppLogger.audio.info("AudioStreamEngine recording started successfully")
            return true
        } catch {
            AppLogger.audio.error("Failed to start AudioStreamEngine: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Stops microphone tap and engine recording.
    func stopCapture() {
        guard isRecording else { return }
        isRecording = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        DispatchQueue.main.async {
            self.currentAudioLevel = 0.0
        }
        AppLogger.audio.info("AudioStreamEngine recording stopped")
    }
    
    // MARK: - Streaming Playback Engine
    
    /// Enqueues and plays incoming real-time audio data frame from network packet.
    func playAudioChunk(_ data: Data) {
        calculateAudioLevel(from: data)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let buffer = dataToPCMBuffer(data, format: format) else { return }
        
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                AppLogger.audio.error("Engine start failed for playback: \(error.localizedDescription)")
            }
        }
        
        if !playerNode.isPlaying {
            playerNode.play()
        }
        
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }
    
    /// Plays standard radio connection chirp audio tone
    func playConnectChirp() {
        AudioServicesPlaySystemSound(1109) // Standard iOS tactical alert tone
    }
    
    // MARK: - Real-Time Audio Power Level Calculation
    
    private func calculateAudioLevel(from data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            let sampleCount = data.count / 2
            guard sampleCount > 0 else { return }
            
            var sumOfSquares: Float = 0.0
            for i in 0..<sampleCount {
                let sample = Float(int16Ptr[i]) / 32768.0
                sumOfSquares += sample * sample
            }
            let rms = sqrt(sumOfSquares / Float(sampleCount))
            let level = min(max(rms * 6.0, 0.0), 1.0)
            
            DispatchQueue.main.async {
                self.currentAudioLevel = level
            }
        }
    }
    
    // MARK: - Helpers
    
    private func pcmBufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        let channelCount = Int(buffer.format.channelCount)
        let length = Int(buffer.frameLength) * channelCount * 2 // 16-bit = 2 bytes
        guard let channelData = buffer.int16ChannelData else { return nil }
        return Data(bytes: channelData[0], count: length)
    }
    
    private func dataToPCMBuffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCapacity = UInt32(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        buffer.frameLength = frameCapacity
        
        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                memcpy(buffer.int16ChannelData?[0], baseAddress, data.count)
            }
        }
        return buffer
    }
}

