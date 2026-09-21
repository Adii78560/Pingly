//
//  AudioStreamEngine.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import AVFoundation
import AudioToolbox
import Combine
import os

extension Notification.Name {
    static let audioStreamEngineDidPlayAudioChunk = Notification.Name("AudioStreamEngineDidPlayAudioChunk")
}

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
    let playerNode = AVAudioPlayerNode()  // internal: accessed by WalkieTalkieNetworkManager for channel-switch cutoff
    private let bandpassEQ = AVAudioUnitEQ(numberOfBands: 2)
    
    private(set) var isRecording = false
    private let audioQueue = DispatchQueue(label: "com.pingly.audiostream", qos: .userInteractive)
    
    #if targetEnvironment(simulator)
    private var simulatorTimer: DispatchSourceTimer?
    #endif
    
    private override init() {
        super.init()
        setupEngineNodes()
    }
    
    // MARK: - Setup & Recovery Engine Architecture
    
    private func setupEngineNodes() {
        // Enable Voice Processing (Voice Isolation, Acoustic Echo Cancellation, Noise Suppression)
        do {
            try audioEngine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
        }
        
        // Attach player node to engine
        audioEngine.attach(playerNode)
        
        // Connect player directly to main mixer using hardware output format
        let mixerFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: mixerFormat)
    }
    
    /// Prepares player and engine nodes following an interruption recovery.
    func preparePlaybackEngine() {
        #if !targetEnvironment(simulator)
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        #endif
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }
    
    /// Completely tears down and reconstructs the AVAudioEngine upon media server reset.
    func reconstructAudioEngine() {
        stopCapture()
        playerNode.stop()
        audioEngine.stop()
        audioEngine.reset()
        
        setupEngineNodes()
        
        #if !targetEnvironment(simulator)
        do {
            try audioEngine.start()
            playerNode.play()
        } catch {
        }
        #endif
    }
    
    // MARK: - Public Recording Engine
    
    /// Starts capturing live microphone audio buffer chunks (20ms frames).
    func startCapture() -> Bool {
        BackgroundAudioSessionManager.shared.configureAudioSession()
        
        #if targetEnvironment(simulator)
        isRecording = true
        simulatorTimer?.cancel()
        simulatorTimer = DispatchSource.makeTimerSource(queue: audioQueue)
        simulatorTimer?.schedule(deadline: .now(), repeating: .milliseconds(20))
        simulatorTimer?.setEventHandler { [weak self] in
            guard let self = self, self.isRecording else { return }
            let emptyData = Data(count: 640)
            self.delegate?.audioStreamEngine(self, didCaptureAudioChunk: emptyData)
            DispatchQueue.main.async {
                self.currentAudioLevel = 0.5
            }
        }
        simulatorTimer?.resume()
        return true
        #else
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
            return true
        } catch {
            return false
        }
        #endif
    }
    
    /// Stops microphone tap and engine recording idempotently to conserve battery power.
    func stopCapture() {
        isRecording = false
        #if targetEnvironment(simulator)
        simulatorTimer?.cancel()
        simulatorTimer = nil
        #else
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning && !playerNode.isPlaying {
            audioEngine.stop()
        }
        #endif
        DispatchQueue.main.async {
            self.currentAudioLevel = 0.0
        }
        BackgroundAudioSessionManager.shared.deactivateAudioSession()
    }

    
    // MARK: - Streaming Playback Engine
    
    private var highestPlayedSequenceNo: UInt16? = nil
    
    /// Resets the monotonic sequence tracker when starting a new stream session.
    func resetSequenceTracker() {
        highestPlayedSequenceNo = nil
    }
    
    /// Enqueues and plays incoming real-time audio data frame from network packet,
    /// rejecting out-of-order or duplicate jitter packets.
    func playAudioChunk(_ data: Data, sequenceNumber: UInt16? = nil) {
        guard !data.isEmpty else { return }
        
        // Sequence & Jitter Protection (accounting for UInt16 wraparound)
        if let incomingSeq = sequenceNumber {
            if let highestSeq = highestPlayedSequenceNo {
                let diff = Int16(bitPattern: incomingSeq &- highestSeq)
                if diff <= 0 {
                    return
                }
            }
            highestPlayedSequenceNo = incomingSeq
        }
        
        NotificationCenter.default.post(
            name: .audioStreamEngineDidPlayAudioChunk,
            object: self,
            userInfo: ["data": data]
        )
        
        calculateAudioLevel(from: data)
        
        let mixerFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        guard let buffer = dataToPCMBuffer(data, targetFormat: mixerFormat) else { return }
        
        #if !targetEnvironment(simulator)
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                return
            }
        }
        #endif
        
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
        
        // Apply soft knee limiting / clamping (-1.0 to 1.0)
        for i in 0..<Int(sampleCount) {
            var sampleFloat = Float(sourceInt16[i]) / 32768.0
            
            // Soft knee compression above 0.7
            let threshold: Float = 0.7
            if sampleFloat > threshold {
                sampleFloat = threshold + (sampleFloat - threshold) / (1.0 + (sampleFloat - threshold) * 2.0)
            } else if sampleFloat < -threshold {
                sampleFloat = -threshold + (sampleFloat + threshold) / (1.0 - (sampleFloat + threshold) * 2.0)
            }
            
            sampleFloat = max(-1.0, min(1.0, sampleFloat))
            sourceInt16[i] = Int16(sampleFloat * 32767.0)
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

