//
//  VoiceStorageManager.swift
//  Relyvo
//
//  Post-Transmission M4A/AAC Audio Conversion & LRU Voice Storage Retention Manager
//

import Foundation
import AVFoundation
import UIKit
import Combine
import SwiftData
import os

/// Manager handling post-transmission M4A compression, WAV cleanup, and LRU disk retention.
final class VoiceStorageManager: ObservableObject {
    
    static let shared = VoiceStorageManager()
    
    /// Max storage allowed for VoiceNotes directory (100 MB)
    static let maxStorageBytes: Int64 = 100 * 1024 * 1024
    
    /// Target storage size after LRU pruning (80 MB)
    static let targetStorageBytes: Int64 = 80 * 1024 * 1024
    
    /// Max retention age before eviction (7 days)
    static let maxRetentionDays: TimeInterval = 7.0 * 24.0 * 60.0 * 60.0
    
    private let compressionQueue = DispatchQueue(label: "com.pingly.voice.compression", qos: .utility)
    private let prunerQueue = DispatchQueue(label: "com.pingly.voice.storage.pruner", qos: .background)
    
    private init() {}
    
    /// Returns the canonical Documents/VoiceNotes directory URL.
    var voiceNotesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("VoiceNotes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    // MARK: - Lifecycle & Observers
    
    /// Starts background observers for periodic and foreground maintenance.
    func startStorageMonitoring() {
        // Run initial prune on launch
        pruneStorageAsync()
        
        // Listen for app foregrounding to prune stale voice notes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func handleAppForeground() {
        pruneStorageAsync()
    }
    
    // MARK: - Post-Transmission M4A/AAC Compression
    
    /// Asynchronously compresses a recorded WAV file to M4A (AAC 32kbps, 16kHz mono),
    /// deletes the source WAV file, and updates SwiftData records.
    func compressWAVToM4A(
        wavURL: URL,
        sessionID: UUID,
        completion: ((Result<URL, Error>) -> Void)? = nil
    ) {
        compressionQueue.async { [weak self] in
            guard let self = self else { return }
            
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: wavURL.path) else {
                let err = NSError(domain: "VoiceStorageManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source WAV file not found"])
                completion?(.failure(err))
                return
            }
            
            let origBytes = (try? fileManager.attributesOfItem(atPath: wavURL.path)[.size] as? Int64) ?? 0
            let m4aURL = self.voiceNotesDirectory.appendingPathComponent("\(sessionID.uuidString).m4a")
            
            do {
                let sourceFile = try AVAudioFile(forReading: wavURL)
                
                // M4A AAC Settings: 16kHz, 1 channel, 32 kbps
                let outputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16000.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32000
                ]
                
                // Remove pre-existing M4A if any
                if fileManager.fileExists(atPath: m4aURL.path) {
                    try? fileManager.removeItem(at: m4aURL)
                }
                
                let destinationFile = try AVAudioFile(
                    forWriting: m4aURL,
                    settings: outputSettings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                
                guard let converter = AVAudioConverter(from: sourceFile.processingFormat, to: destinationFile.processingFormat) else {
                    throw NSError(domain: "VoiceStorageManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize AVAudioConverter"])
                }
                
                let bufferCapacity: AVAudioFrameCount = 4096
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: bufferCapacity),
                      let outputBuffer = AVAudioPCMBuffer(pcmFormat: destinationFile.processingFormat, frameCapacity: bufferCapacity) else {
                    throw NSError(domain: "VoiceStorageManager", code: 501, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio buffers"])
                }
                
                while sourceFile.framePosition < sourceFile.length {
                    try sourceFile.read(into: inputBuffer)
                    guard inputBuffer.frameLength > 0 else { break }
                    
                    var convError: NSError?
                    let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                    
                    let status = converter.convert(to: outputBuffer, error: &convError, withInputFrom: inputBlock)
                    if let convError = convError {
                        throw convError
                    }
                    if status == .error {
                        break
                    }
                    if outputBuffer.frameLength > 0 {
                        try destinationFile.write(from: outputBuffer)
                    }
                }
                
                // Intermediate WAV deletion
                try fileManager.removeItem(at: wavURL)
                
                let compBytes = (try? fileManager.attributesOfItem(atPath: m4aURL.path)[.size] as? Int64) ?? 0
                _ = origBytes > 0 ? Int((Double(origBytes - compBytes) / Double(origBytes)) * 100.0) : 0
                
                
                // Update SwiftData record on main thread
                Task { @MainActor in
                    await SwiftDataService.shared.persistenceActor.updateVoiceMessageFilePath(sessionID: sessionID, newPath: m4aURL.path)
                    // Run background retention pruner after new compression
                    self.pruneStorageAsync()
                }
                
                completion?(.success(m4aURL))
            } catch {
                completion?(.failure(error))
            }
        }
    }
    
    // MARK: - Voice Storage Retention & LRU Pruning
    
    /// Triggers asynchronous pruning of the VoiceNotes directory.
    func pruneStorageAsync(completion: ((Int, Int64) -> Void)? = nil) {
        prunerQueue.async { [weak self] in
            guard let self = self else { return }
            let res = self.pruneStorage()
            completion?(res.deletedFiles, res.freedBytes)
        }
    }
    
    /// Synchronous execution of storage retention policies.
    @discardableResult
    func pruneStorage() -> (deletedFiles: Int, freedBytes: Int64) {
        let fileManager = FileManager.default
        let dir = self.voiceNotesDirectory
        
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return (0, 0)
        }
        
        var deletedCount = 0
        var freedBytes: Int64 = 0
        let now = Date()
        
        struct FileMeta {
            let url: URL
            let modDate: Date
            let size: Int64
        }
        
        var remainingFiles: [FileMeta] = []
        var totalFolderBytes: Int64 = 0
        
        // 1. Age-Based Eviction (> 7 Days)
        for url in fileURLs {
            guard let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modDate = resourceValues.contentModificationDate,
                  let size = resourceValues.fileSize else {
                continue
            }
            
            let fileSize = Int64(size)
            let age = now.timeIntervalSince(modDate)
            
            if age > Self.maxRetentionDays {
                do {
                    try fileManager.removeItem(at: url)
                    deletedCount += 1
                    freedBytes += fileSize
                } catch {
                }
            } else {
                remainingFiles.append(FileMeta(url: url, modDate: modDate, size: fileSize))
                totalFolderBytes += fileSize
            }
        }
        
        // 2. Capacity-Based LRU Eviction (> 100 MB -> Prune to <= 80 MB)
        if totalFolderBytes > Self.maxStorageBytes {
            // Sort oldest modified first
            let sortedOldestFirst = remainingFiles.sorted { $0.modDate < $1.modDate }
            
            for file in sortedOldestFirst {
                guard totalFolderBytes > Self.targetStorageBytes else { break }
                
                do {
                    try fileManager.removeItem(at: file.url)
                    deletedCount += 1
                    freedBytes += file.size
                    totalFolderBytes -= file.size
                } catch {
                }
            }
        }
        
        
        return (deletedCount, freedBytes)
    }
}
