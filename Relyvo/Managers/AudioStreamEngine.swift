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
    
    // Voice playback format: 16kHz Float32 mono
    let voicePlaybackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    
    private var isPlayingAudio: Bool = false
    private let playbackLock = NSLock()
    private var preRollBufferCount: Int = 0
    private var captureAccumulator = Data()
    
    private override init() {
        super.init()
        setupEngineNodes()
    }
    
    // MARK: - Setup & Recovery Engine Architecture
    
    private func setupEngineNodes() {
        // Enable Voice Processing (Voice Isolation, Acoustic Echo Cancellation, Noise Suppression)
        do {
            try audioEngine.inputNode.setVoiceProcessingEnabled(true)
            AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] Voice processing enabled on inputNode")
        } catch {
            AppLogger.audio.error("[PTT_DIAG][AudioStreamEngine] ❌ Voice processing setup FAILED: \(error.localizedDescription)")
        }
        
        // Attach player node to engine
        audioEngine.attach(playerNode)
        
        // Connect player directly to main mixer using voice playback format (16kHz Float32 Mono)
        // AVAudioEngine's internal mixer will smoothly and continuously resample to hardware rate
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: voicePlaybackFormat)
        AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] Engine nodes setup complete. Connected playerNode with format: \(self.voicePlaybackFormat.description)")
    }
    
    func startPlayback() {
        playbackLock.lock()
        guard !isPlayingAudio else {
            playbackLock.unlock()
            return
        }
        isPlayingAudio = true
        playbackLock.unlock()
        AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] ▶️ startPlayback() — incrementing active session")
        BackgroundAudioSessionManager.shared.incrementActiveSession()
        preparePlaybackEngine()
    }
    
    func stopPlayback() {
        playbackLock.lock()
        guard isPlayingAudio else {
            preRollBufferCount = 0
            playbackLock.unlock()
            return
        }
        isPlayingAudio = false
        preRollBufferCount = 0
        playbackLock.unlock()
        playerNode.stop()
        highestPlayedSequenceNo = nil
        AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] ⏹️ stopPlayback() — playerNode stopped, decrementing active session")
        BackgroundAudioSessionManager.shared.decrementActiveSession()
    }
    
    /// Flushes any pending pre-roll frames so short transmissions play completely before stopping.
    func flushPendingPlayback() {
        playbackLock.lock()
        let shouldStart = !isPlayingAudio && preRollBufferCount > 0
        playbackLock.unlock()
        if shouldStart {
            startPlayback()
        }
    }
    
    /// Prepares player and engine nodes following an interruption recovery.
    func preparePlaybackEngine() {
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }
    
    /// Completely tears down and reconstructs the AVAudioEngine upon media server reset.
    func reconstructAudioEngine() {
        stopCapture()
        stopPlayback()
        audioEngine.stop()
        audioEngine.reset()
        
        setupEngineNodes()
        
        do {
            try audioEngine.start()
            playerNode.play()
        } catch {
        }
    }
    
    // MARK: - Public Recording Engine
    
    private var simulatorTonePhase: Double = 0.0
    
    #if targetEnvironment(simulator)
    private func startSimulatorToneCapture() -> Bool {
        isRecording = true
        simulatorTimer?.cancel()
        simulatorTimer = DispatchSource.makeTimerSource(queue: audioQueue)
        simulatorTimer?.schedule(deadline: .now(), repeating: .milliseconds(20))
        simulatorTimer?.setEventHandler { [weak self] in
            guard let self = self, self.isRecording else { return }
            
            // 320 samples (20ms at 16kHz) of an audible 520Hz radio modulation tone so receiving peers actually hear sound!
            var samples = [Int16](repeating: 0, count: 320)
            for i in 0..<320 {
                let frequency: Double = 520.0
                let sampleValue = sin(self.simulatorTonePhase) * 16000.0
                samples[i] = Int16(sampleValue)
                self.simulatorTonePhase += 2.0 * .pi * frequency / 16000.0
                if self.simulatorTonePhase > 2.0 * .pi {
                    self.simulatorTonePhase -= 2.0 * .pi
                }
            }
            let toneData = samples.withUnsafeBytes { Data($0) }
            self.delegate?.audioStreamEngine(self, didCaptureAudioChunk: toneData)
            DispatchQueue.main.async {
                self.currentAudioLevel = 0.6
            }
        }
        simulatorTimer?.resume()
        AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] 🎙️ Simulator audible radio tone capture started (520Hz tone)")
        return true
    }
    #endif
    
    /// Starts capturing live microphone audio buffer chunks (20ms frames).
    func startCapture() -> Bool {
        AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] 🎙️ startCapture() called. isRecording=\(self.isRecording) engineRunning=\(self.audioEngine.isRunning)")
        BackgroundAudioSessionManager.shared.configureAudioSession()
        BackgroundAudioSessionManager.shared.incrementActiveSession()
        
        audioQueue.sync {
            self.captureAccumulator.removeAll()
        }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] InputNode format: sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) commonFormat=\(inputFormat.commonFormat.rawValue)")
        
        // Target 16kHz mono format for P2P network stream efficiency
        guard inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let formatConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            
            AppLogger.audio.warning("[PTT_DIAG][AudioStreamEngine] ⚠️ Hardware mic tap unavailable (channels=\(inputFormat.channelCount)). Using synthetic audible radio tone.")
            #if targetEnvironment(simulator)
            return startSimulatorToneCapture()
            #else
            return false
            #endif
        }
        
        AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] Format converter created: \(inputFormat.sampleRate)Hz -> 16kHz mono")
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
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
            
            let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * (16000.0 / inputFormat.sampleRate) + 200)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                AppLogger.audio.error("[PTT_DIAG][AudioStreamEngine] ❌ Failed to allocate PCM conversion buffer")
                return
            }
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
            
            if let error = error {
                AppLogger.audio.error("[PTT_DIAG][AudioStreamEngine] ❌ Format conversion error: \(error.localizedDescription)")
            }
            
            if (status == .haveData || status == .inputRanDry), let data = self.pcmBufferToData(convertedBuffer) {
                self.audioQueue.async { [weak self] in
                    guard let self = self, self.isRecording else { return }
                    self.captureAccumulator.append(data)
                    // Dispatch in exact 20ms frames (320 samples of 16-bit Int16 = 640 bytes)
                    while self.captureAccumulator.count >= 640 {
                        let chunk = self.captureAccumulator.prefix(640)
                        self.captureAccumulator.removeFirst(640)
                        self.delegate?.audioStreamEngine(self, didCaptureAudioChunk: Data(chunk))
                    }
                }
            }
        }
        
        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
                AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] ✅ AVAudioEngine started successfully")
            }
            isRecording = true
            AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] ✅ Microphone tap installed. isRecording=true. delegate=\(self.delegate != nil ? "SET" : "NIL")")
            return true
        } catch {
            AppLogger.audio.error("[PTT_DIAG][AudioStreamEngine] ❌ AVAudioEngine start FAILED: \(error.localizedDescription)")
            #if targetEnvironment(simulator)
            return startSimulatorToneCapture()
            #else
            return false
            #endif
        }
    }
    
    /// Stops microphone tap and engine recording idempotently to conserve battery power.
    func stopCapture() {
        guard isRecording else {
            AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] stopCapture() skipped — not recording")
            return
        }
        isRecording = false
        audioQueue.sync {
            self.captureAccumulator.removeAll()
        }
        AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] ⏹️ stopCapture() — removing mic tap. engineRunning=\(self.audioEngine.isRunning) playerPlaying=\(self.playerNode.isPlaying)")
        #if targetEnvironment(simulator)
        simulatorTimer?.cancel()
        simulatorTimer = nil
        #endif
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning && !playerNode.isPlaying {
            audioEngine.stop()
            AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] AVAudioEngine stopped (no active playback)")
        }
        DispatchQueue.main.async {
            self.currentAudioLevel = 0.0
        }
        BackgroundAudioSessionManager.shared.decrementActiveSession()
    }
    
    /// Requests microphone recording permission from the system if not already granted.
    func requestMicrophonePermission(completion: ((Bool) -> Void)? = nil) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] Microphone permission: \(granted)")
                DispatchQueue.main.async {
                    completion?(granted)
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] Microphone permission: \(granted)")
                DispatchQueue.main.async {
                    completion?(granted)
                }
            }
        }
    }

    
    // MARK: - Streaming Playback Engine
    
    private(set) var highestPlayedSequenceNo: UInt16? = nil
    
    /// Resets the monotonic sequence tracker and pre-roll buffers when starting a new stream session.
    func resetSequenceTracker() {
        playbackLock.lock()
        highestPlayedSequenceNo = nil
        preRollBufferCount = 0
        playbackLock.unlock()
    }
    
    /// Enqueues and plays incoming real-time audio data frame from network packet,
    /// rejecting out-of-order or duplicate jitter packets.
    func playAudioChunk(_ data: Data, sequenceNumber: UInt16? = nil) {
        guard !data.isEmpty else {
            AppLogger.audio.warning("[PTT_DIAG][AudioStreamEngine] playAudioChunk() called with EMPTY data")
            return
        }
        
        // Sequence & Jitter Protection (accounting for UInt16 wraparound)
        if let incomingSeq = sequenceNumber {
            if let highestSeq = highestPlayedSequenceNo {
                let diff = Int16(bitPattern: incomingSeq &- highestSeq)
                if diff <= 0 {
                    AppLogger.audio.debug("[PTT_DIAG][AudioStreamEngine] Duplicate/old seq rejected: incoming=\(incomingSeq) highest=\(highestSeq)")
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
        
        guard let buffer = dataToPCMBuffer(data) else {
            AppLogger.audio.error("[PTT_DIAG][AudioStreamEngine] ❌ dataToPCMBuffer conversion FAILED for \(data.count) bytes")
            return
        }
        
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                AppLogger.audio.info("[PTT_DIAG][AudioStreamEngine] Engine restarted for playback")
            } catch {
                AppLogger.audio.error("[PTT_DIAG][AudioStreamEngine] ❌ Engine restart FAILED for playback: \(error.localizedDescription)")
                return
            }
        }
        
        playbackLock.lock()
        preRollBufferCount += 1
        let currentQueued = preRollBufferCount
        let currentlyPlaying = isPlayingAudio
        playbackLock.unlock()
        
        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self = self else { return }
            self.playbackLock.lock()
            self.preRollBufferCount = max(0, self.preRollBufferCount - 1)
            self.playbackLock.unlock()
        }
        
        if !currentlyPlaying {
            // Pre-roll: hold 2 chunks (40ms) before starting player to eliminate network jitter starvation
            if currentQueued >= 2 {
                startPlayback()
            }
        } else if !playerNode.isPlaying {
            playerNode.play()
        }
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
    
    /// Converts 16kHz Int16 mono PCM data directly into a 16kHz Float32 mono buffer for hardware mixer playback.
    /// Completely avoids software resampler allocation or filter discontinuity artifacts!
    private func dataToPCMBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: voicePlaybackFormat, frameCapacity: UInt32(sampleCount)) else {
            return nil
        }
        buffer.frameLength = UInt32(sampleCount)
        
        guard let floatChannel = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                let sampleFloat = Float(int16Ptr[i]) / 32768.0
                floatChannel[i] = max(-1.0, min(1.0, sampleFloat))
            }
        }
        return buffer
    }
}

