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
        
        // Attach player node to engine
        audioEngine.attach(playerNode)
        
        // Connect player directly to main mixer using hardware output format
        let mixerFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: mixerFormat)
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
            
            // Forward buffer to live speech transcriber
            SpeechTranscriberManager.shared.processAudioBuffer(buffer)
            
            // Direct float buffer RMS level calculation
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
            
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize) else { return }
            var error: NSError?
            var hasProvidedData = false
            
            let status = formatConverter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if !hasProvidedData {
                    outStatus.pointee = .haveData
                    hasProvidedData = true
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            
            if (status == .haveData || status == .inputRanDry), let data = self.pcmBufferToData(convertedBuffer) {
                self.delegate?.audioStreamEngine(self, didCaptureAudioChunk: data)
            }
        }
        
        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            isRecording = true
            AppLogger.audio.info("AudioStreamEngine recording started successfully")
            return true
        } catch {
            AppLogger.audio.error("Failed to start AudioStreamEngine: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Stops microphone tap and engine recording idempotently to conserve battery power.
    func stopCapture() {
        isRecording = false
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning && !playerNode.isPlaying {
            audioEngine.stop()
        }
        DispatchQueue.main.async {
            self.currentAudioLevel = 0.0
        }
        BackgroundAudioSessionManager.shared.deactivateAudioSession()
        AppLogger.audio.info("AudioStreamEngine recording stopped & audio session deactivated")
    }

    
    // MARK: - Streaming Playback Engine
    
    /// Enqueues and plays incoming real-time audio data frame from network packet.
    func playAudioChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        calculateAudioLevel(from: data)
        
        let mixerFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        guard let buffer = dataToPCMBuffer(data, targetFormat: mixerFormat) else { return }
        
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                AppLogger.audio.error("Engine start failed for playback: \(error.localizedDescription)")
                return
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
        guard let channelData = buffer.int16ChannelData, length > 0 else { return nil }
        return Data(bytes: channelData[0], count: length)
    }
    
    private func dataToPCMBuffer(_ data: Data, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sourceSampleRate: Double = 16000.0
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sourceSampleRate, channels: 1, interleaved: true) else { return nil }
        
        let sampleCount = data.count / 2
        guard sampleCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: UInt32(sampleCount)) else { return nil }
        sourceBuffer.frameLength = UInt32(sampleCount)
        
        guard let sourceInt16 = sourceBuffer.int16ChannelData?[0] else { return nil }
        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                memcpy(sourceInt16, baseAddress, data.count)
            }
        }
        
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        let targetFrameCapacity = UInt32(Double(sampleCount) * (targetFormat.sampleRate / sourceSampleRate)) + 100
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCapacity) else { return nil }
        
        var error: NSError?
        var hasProvidedData = false
        let status = converter.convert(to: targetBuffer, error: &error) { _, outStatus in
            if !hasProvidedData {
                outStatus.pointee = .haveData
                hasProvidedData = true
                return sourceBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        return (status == .haveData || status == .inputRanDry) ? targetBuffer : nil
    }
}

