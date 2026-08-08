//
//  SwiftDataService.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import SwiftData
import Combine
import os


/// Thread-safe SwiftData Manager handling channel-partitioned local storage and cloud sync readiness.
@MainActor
final class SwiftDataService: ObservableObject {
    
    static let shared = SwiftDataService()
    
    let container: ModelContainer
    var context: ModelContext {
        container.mainContext
    }
    
    @Published private(set) var totalUnsyncedCount: Int = 0
    
    private init() {
        do {
            let schema = Schema([
                SDVoiceTranscript.self,
                SDChatMessage.self
            ])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            self.container = try ModelContainer(for: schema, configurations: [config])
            AppLogger.multipeer.info("SwiftData ModelContainer initialized successfully.")
            updateUnsyncedCount()
        } catch {
            fatalError("Failed to initialize SwiftData ModelContainer: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Voice Transcripts Operations
    
    /// Persists a voice transcript to SwiftData local storage.
    func saveVoiceTranscript(speakerName: String, text: String, channel: String) -> SDVoiceTranscript {
        let transcript = SDVoiceTranscript(
            speakerName: speakerName,
            text: text,
            channel: channel,
            timestamp: Date(),
            isSynced: false
        )
        context.insert(transcript)
        saveContext()
        updateUnsyncedCount()
        AppLogger.audio.info("Persisted Voice Transcript to SwiftData: [\(channel)] \(speakerName): \"\(text)\"")
        return transcript
    }
    
    /// Fetches all stored voice transcripts for a specific channel sorted by timestamp.
    func fetchTranscripts(for channel: String) -> [VoiceTranscript] {
        let targetChannel = channel.uppercased()
        let descriptor = FetchDescriptor<SDVoiceTranscript>(
            predicate: #Predicate { $0.channel == targetChannel },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        
        do {
            let results = try context.fetch(descriptor)
            return results.map { item in
                VoiceTranscript(
                    id: item.id,
                    speakerName: item.speakerName,
                    text: item.text,
                    channel: item.channel,
                    timestamp: item.timestamp
                )
            }
        } catch {
            AppLogger.audio.error("Failed to fetch transcripts for \(channel): \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - Chat Messages Operations
    
    /// Persists a chat message to SwiftData local storage.
    func saveChatMessage(senderName: String, channel: String, text: String) -> SDChatMessage {
        let message = SDChatMessage(
            senderName: senderName,
            channel: channel,
            text: text,
            timestamp: Date(),
            isSynced: false
        )
        context.insert(message)
        saveContext()
        updateUnsyncedCount()
        AppLogger.multipeer.info("Persisted Chat Message to SwiftData: [\(channel)] \(senderName): \"\(text)\"")
        return message
    }
    
    /// Fetches all stored chat messages for a specific channel sorted by timestamp.
    func fetchChatMessages(for channel: String) -> [SDChatMessage] {
        let targetChannel = channel.uppercased()
        let descriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.channel == targetChannel },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLogger.multipeer.error("Failed to fetch messages for \(channel): \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - Cloud Sync Readiness Operations
    
    /// Fetches all items pending cloud synchronization when internet connectivity becomes available.
    func fetchUnsyncedItems() -> (transcripts: [SDVoiceTranscript], messages: [SDChatMessage]) {
        let transcriptDescriptor = FetchDescriptor<SDVoiceTranscript>(
            predicate: #Predicate { !$0.isSynced }
        )
        let messageDescriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { !$0.isSynced }
        )
        
        let unsyncedTranscripts = (try? context.fetch(transcriptDescriptor)) ?? []
        let unsyncedMessages = (try? context.fetch(messageDescriptor)) ?? []
        
        return (unsyncedTranscripts, unsyncedMessages)
    }
    
    /// Marks specified transcripts and messages as synchronized after pushing to Cloud.
    func markAsSynced(transcriptIDs: [UUID], messageIDs: [UUID]) {
        let (transcripts, messages) = fetchUnsyncedItems()
        
        for item in transcripts where transcriptIDs.contains(item.id) {
            item.isSynced = true
        }
        for item in messages where messageIDs.contains(item.id) {
            item.isSynced = true
        }
        
        saveContext()
        updateUnsyncedCount()
        AppLogger.multipeer.info("Marked \(transcriptIDs.count) transcripts & \(messageIDs.count) messages as synced to Cloud.")
    }
    
    // MARK: - Private Helpers
    
    private func saveContext() {
        do {
            try context.save()
        } catch {
            AppLogger.multipeer.error("Error saving SwiftData ModelContext: \(error.localizedDescription)")
        }
    }
    
    private func updateUnsyncedCount() {
        let (transcripts, messages) = fetchUnsyncedItems()
        self.totalUnsyncedCount = transcripts.count + messages.count
    }
}
