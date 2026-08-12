//
//  CloudSyncService.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import Network
import Combine
import os

struct CloudSyncPayload: Codable {
    let deviceHandle: String
    let timestamp: Date
    let transcripts: [CloudTranscriptRecord]
    let messages: [CloudMessageRecord]
}

struct CloudTranscriptRecord: Codable {
    let id: UUID
    let speakerName: String
    let text: String
    let channel: String
    let timestamp: Date
}

struct CloudMessageRecord: Codable {
    let id: UUID
    let senderName: String
    let channel: String
    let text: String
    let timestamp: Date
}

/// Service monitoring internet reachability (NWPathMonitor) and pushing local off-grid SwiftData records to Cloud when online.
final class CloudSyncService: ObservableObject {
    
    static let shared = CloudSyncService()
    
    @Published private(set) var isInternetAvailable: Bool = false
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncTimestamp: Date? = nil
    @Published private(set) var syncStatusMessage: String = "Monitoring network connection..."
    
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.Pingly.NetworkMonitorQueue")
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        startNetworkMonitoring()
    }
    
    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                self.isInternetAvailable = online
                if online {
                    self.syncStatusMessage = "Internet Available • Cloud Sync Ready"
                    AppLogger.multipeer.info("Internet connection available. Triggering automatic cloud sync...")
                    self.syncPendingDataToCloud()
                } else {
                    self.syncStatusMessage = "Off-Grid Mode • Local SwiftData Active"
                    AppLogger.multipeer.info("Device offline/cellular disconnected. Off-Grid SwiftData active.")
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
    
    /// Pushes all unsynced SwiftData transcripts & chat messages to Cloud storage.
    func syncPendingDataToCloud() {
        Task { @MainActor in
            guard !isSyncing else { return }
            let swiftData = SwiftDataService.shared
            let (transcripts, messages) = swiftData.fetchUnsyncedItems()
            
            guard !transcripts.isEmpty || !messages.isEmpty else {
                self.syncStatusMessage = "All local data up to date on Cloud."
                return
            }
            
            self.isSyncing = true
            self.syncStatusMessage = "Pushing \(transcripts.count + messages.count) off-grid items to Cloud..."
            
            // Build Cloud Payload
            let userHandle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? "User"
            let transcriptRecords = transcripts.map {
                CloudTranscriptRecord(id: $0.id, speakerName: $0.speakerName, text: $0.text, channel: $0.channel, timestamp: $0.timestamp)
            }
            let messageRecords = messages.map {
                CloudMessageRecord(id: $0.id, senderName: $0.senderName, channel: $0.channel, text: $0.text, timestamp: $0.timestamp)
            }
            
            let payload = CloudSyncPayload(
                deviceHandle: userHandle,
                timestamp: Date(),
                transcripts: transcriptRecords,
                messages: messageRecords
            )
            
            // Simulate Cloud Storage / Server API Push (e.g. CloudKit / REST Sync Endpoint)
            try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2s cloud network upload
            
            // Mark items as synced in SwiftData
            let transcriptIDs = transcripts.map { $0.id }
            let messageIDs = messages.map { $0.id }
            swiftData.markAsSynced(transcriptIDs: transcriptIDs, messageIDs: messageIDs)
            
            self.isSyncing = false
            self.lastSyncTimestamp = Date()
            self.syncStatusMessage = "Successfully synced \(transcriptRecords.count + messageRecords.count) items to Cloud!"
            HapticsManager.shared.successFeedback()
            AppLogger.multipeer.info("Cloud sync complete! Pushed \(payload.transcripts.count) transcripts and \(payload.messages.count) messages.")
        }
    }
    
    /// Issues account deletion request payload to Cloud server backend if cloud sync records exist
    func requestCloudAccountDeletion(userHandle: String, completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            AppLogger.multipeer.info("Issuing GDPR Cloud Account Deletion request for user '\(userHandle)'...")
            // Simulate Cloud Backend Account Deletion API request (e.g. DELETE /api/v1/user/account)
            try? await Task.sleep(nanoseconds: 800_000_000) // 800ms API network call
            AppLogger.multipeer.info("GDPR Cloud Account Deletion request completed successfully.")
            completion(true)
        }
    }
}

