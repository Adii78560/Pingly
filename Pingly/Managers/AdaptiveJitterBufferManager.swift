//
//  AdaptiveJitterBufferManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import Combine
import os

struct BufferedAudioFrame {
    let sequenceNo: UInt16
    let timestampMs: UInt32
    let pcmData: Data
    let arrivalTime: Date
}

/// Adaptive Jitter Buffer Manager based on WebRTC NetEQ design principles.
/// Buffers 40-60ms of decoded frames before starting playback and dynamically adjusts
/// buffer depth based on network transit jitter.
final class AdaptiveJitterBufferManager {
    
    static let shared = AdaptiveJitterBufferManager()
    
    // MARK: - Jitter Metrics & Configuration
    private var frameQueue: [BufferedAudioFrame] = []
    private var isBuffering: Bool = true
    private var targetBufferDepth: Int = 2 // 2 frames = 40ms default pre-buffer
    private let minBufferDepth: Int = 2    // 40ms min
    private let maxBufferDepth: Int = 6    // 120ms max
    
    private var timer: Timer?
    private var lastArrivalDate: Date?
    private var lastHeaderTimestampMs: UInt32 = 0
    private var smoothedJitterMs: Double = 0.0
    
    private let queueLock = NSLock()
    
    private init() {}
    
    // MARK: - Public Control API
    
    /// Reset jitter buffer state for a new incoming PTT session.
    func resetSession() {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        timer?.invalidate()
        timer = nil
        frameQueue.removeAll()
        isBuffering = true
        targetBufferDepth = 2
        lastArrivalDate = nil
        lastHeaderTimestampMs = 0
        smoothedJitterMs = 0.0
        AppLogger.multipeer.info("Adaptive Jitter Buffer reset for new PTT session.")
    }
    
    /// Enqueues incoming PCM frame, calculates WebRTC NetEQ jitter, and triggers adaptive playback.
    func enqueueFrame(sequenceNo: UInt16, timestampMs: UInt32, pcmData: Data) {
        queueLock.lock()
        
        let now = Date()
        calculateJitterAndUpdateTargetDepth(timestampMs: timestampMs, arrivalTime: now)
        
        let frame = BufferedAudioFrame(
            sequenceNo: sequenceNo,
            timestampMs: timestampMs,
            pcmData: pcmData,
            arrivalTime: now
        )
        
        // Insert frame in sequence order
        if let index = frameQueue.firstIndex(where: { $0.sequenceNo > sequenceNo }) {
            frameQueue.insert(frame, at: index)
        } else {
            frameQueue.append(frame)
        }
        
        let currentCount = frameQueue.count
        queueLock.unlock()
        
        // Check if pre-buffer target is satisfied
        if isBuffering && currentCount >= targetBufferDepth {
            startPlaybackTimer()
        }
    }
    
    /// Flushes remaining queued frames upon PTT_END signal.
    func flushRemainingSession() {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        timer?.invalidate()
        timer = nil
        
        for frame in frameQueue {
            AudioStreamEngine.shared.playAudioChunk(frame.pcmData)
        }
        frameQueue.removeAll()
        isBuffering = false
        AppLogger.multipeer.info("Adaptive Jitter Buffer flushed remaining frames on PTT_END.")
    }
    
    // MARK: - Private WebRTC NetEQ Jitter Logic & Dispatcher
    
    private func startPlaybackTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.queueLock.lock()
            self.isBuffering = false
            self.queueLock.unlock()
            
            self.timer?.invalidate()
            // Fire every 20ms to match 16kHz PCM frame rate
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.020, repeats: true) { [weak self] _ in
                self?.dequeueAndPlayNextFrame()
            }
        }
    }
    
    private func dequeueAndPlayNextFrame() {
        queueLock.lock()
        guard !frameQueue.isEmpty else {
            // Buffer underrun — enter buffering state again
            isBuffering = true
            timer?.invalidate()
            timer = nil
            queueLock.unlock()
            AppLogger.multipeer.warning("Jitter Buffer Underrun! Re-entering 40ms pre-buffer state.")
            return
        }
        
        let frame = frameQueue.removeFirst()
        queueLock.unlock()
        
        AudioStreamEngine.shared.playAudioChunk(frame.pcmData)
    }
    
    private func calculateJitterAndUpdateTargetDepth(timestampMs: UInt32, arrivalTime: Date) {
        if let lastArrival = lastArrivalDate {
            let actualTransitMs = arrivalTime.timeIntervalSince(lastArrival) * 1000.0
            let expectedTransitMs = Double(timestampMs > lastHeaderTimestampMs ? timestampMs - lastHeaderTimestampMs : 20)
            let instantJitter = abs(actualTransitMs - expectedTransitMs)
            
            // Exponential moving average smoothing (NetEQ algorithm)
            smoothedJitterMs = (0.90 * smoothedJitterMs) + (0.10 * instantJitter)
            
            // Adapt target buffer depth: 40ms (2 frames) for stable link, 60-80ms (3-4 frames) for jittery link
            if smoothedJitterMs > 25.0 {
                targetBufferDepth = min(maxBufferDepth, targetBufferDepth + 1)
                AppLogger.multipeer.debug("Increased Jitter Buffer Target Depth to \(self.targetBufferDepth) frames (\(self.targetBufferDepth * 20)ms) due to jitter: \(String(format: "%.1f", self.smoothedJitterMs))ms")
            } else if smoothedJitterMs < 10.0 {
                targetBufferDepth = max(minBufferDepth, targetBufferDepth - 1)
            }
        }
        
        lastArrivalDate = arrivalTime
        lastHeaderTimestampMs = timestampMs
    }
}
