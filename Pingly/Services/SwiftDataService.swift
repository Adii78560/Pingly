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
        let schema = Schema([
            SDVoiceTranscript.self,
            SDChatMessage.self,
            SDPendingMessage.self,
            SDUserProfile.self,
            SDNotificationEvent.self
        ])

        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
            AppLogger.multipeer.info("SwiftData ModelContainer initialized successfully.")
            updateUnsyncedCount()
        } catch {
            AppLogger.multipeer.error("SwiftData schema migration error: \(error.localizedDescription). Purging legacy SQLite store for clean recovery...")
            Self.purgeLegacyStore()
            do {
                self.container = try ModelContainer(for: schema, configurations: [config])
                AppLogger.multipeer.info("SwiftData ModelContainer successfully re-initialized after store purge.")
                updateUnsyncedCount()
            } catch {
                fatalError("Critical: Failed to re-initialize SwiftData ModelContainer: \(error.localizedDescription)")
            }
        }
    }
    
    private static func purgeLegacyStore() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let storeURL = appSupport.appendingPathComponent("default.store")
        let shmURL = appSupport.appendingPathComponent("default.store-shm")
        let walURL = appSupport.appendingPathComponent("default.store-wal")
        
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: shmURL)
        try? FileManager.default.removeItem(at: walURL)
        AppLogger.multipeer.info("Purged incompatible legacy SwiftData SQLite store files.")
    }


    
    // MARK: - Voice Transcripts Operations
    
    /// Persists a voice transcript to SwiftData local storage.
    func saveVoiceTranscript(speakerName: String, text: String, channel: String, isDelivered: Bool = false) -> SDVoiceTranscript {
        let transcript = SDVoiceTranscript(
            speakerName: speakerName,
            text: text,
            channel: channel,
            timestamp: Date(),
            isSynced: false,
            isDelivered: isDelivered
        )
        context.insert(transcript)
        saveContext()
        updateUnsyncedCount()
        AppLogger.audio.info("Persisted Voice Transcript (Delivered: \(isDelivered)): [\(channel)] \(speakerName): \"\(text)\"")
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
                    timestamp: item.timestamp,
                    isDelivered: item.isDelivered
                )
            }
        } catch {
            AppLogger.audio.error("Failed to fetch transcripts for \(channel): \(error.localizedDescription)")
            return []
        }
    }
    
    /// Marks pending transcripts for a channel as delivered when peers join.
    func markTranscriptsAsDelivered(for channel: String) {
        let targetChannel = channel.uppercased()
        let descriptor = FetchDescriptor<SDVoiceTranscript>(
            predicate: #Predicate { $0.channel == targetChannel && !$0.isDelivered }
        )
        if let results = try? context.fetch(descriptor) {
            for item in results {
                item.isDelivered = true
            }
            saveContext()
            AppLogger.multipeer.info("Marked \(results.count) transcripts on '\(channel)' as delivered.")
        }
    }

    
    // MARK: - Chat Messages Operations
    
    /// Persists a chat or location message to SwiftData local storage.
    func saveChatMessage(
        senderName: String,
        channel: String,
        text: String,
        isDelivered: Bool = false,
        messageType: P2PMessageType = .chat,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil,
        accuracy: Double? = nil
    ) -> SDChatMessage {
        let message = SDChatMessage(
            senderName: senderName,
            channel: channel,
            text: text,
            timestamp: Date(),
            isSynced: false,
            isDelivered: isDelivered,
            messageType: messageType,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            accuracy: accuracy
        )
        context.insert(message)
        saveContext()
        updateUnsyncedCount()
        AppLogger.multipeer.info("Persisted Chat Message (Type: \(messageType.rawValue), Delivered: \(isDelivered)): [\(channel)] \(senderName): \"\(text)\"")
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
    
    // MARK: - Store-and-Forward Mesh Queue Operations
    
    private let queueLock = NSLock()
    
    func enqueuePendingMessage(
        messageID: UUID = UUID(),
        originID: String? = nil,
        destinationID: String = "BROADCAST",
        recipientName: String,
        senderName: String,
        previousHopID: String? = nil,
        text: String,
        channel: String = "CH-1 EMERGENCY",
        isSOS: Bool = false,
        priorityRaw: Int = 0,
        queueRole: QueueRole = .origin,
        hopsCount: Int = 0,
        ttl: Int = 5
    ) -> SDPendingMessage? {

        // Enforce 64 KB payload limit for text/transcript envelopes
        guard text.utf8.count <= Constants.Mesh.maxPayloadBytes else {
            AppLogger.multipeer.error("Oversized payload rejected (\(text.utf8.count) bytes > \(Constants.Mesh.maxPayloadBytes) bytes limit).")
            return nil
        }
        
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let existingDescriptor = FetchDescriptor<SDPendingMessage>(
            predicate: #Predicate { $0.messageID == messageID }
        )
        if let existing = try? context.fetch(existingDescriptor).first {
            return existing
        }
        
        let pending = SDPendingMessage(
            messageID: messageID,
            originID: originID ?? senderName,
            destinationID: destinationID,
            recipientName: recipientName,
            senderName: senderName,
            previousHopID: previousHopID,
            text: text,
            channel: channel,
            timestamp: Date(),
            isSOS: isSOS,
            priorityRaw: isSOS ? 2 : priorityRaw,
            status: .queued,
            queueRole: queueRole,
            hopsCount: hopsCount,
            ttl: ttl
        )
        context.insert(pending)
        saveContext()
        
        AppLogger.multipeer.info("""
        [PINGLY_QUEUE_STATE]
        messageID=\(messageID.uuidString)
        messageType=\(queueRole.rawValue)
        destination=\(destinationID)
        channel=\(channel)
        oldStatus=NONE
        newStatus=QUEUED
        attempt=0
        retryCount=0
        timestamp=\(pending.timestamp)
        """)
        
        AppLogger.multipeer.info("Enqueued pending \(queueRole.rawValue) message \(messageID) for recipient '\(recipientName)' (Dest: \(destinationID)): \"\(text.prefix(30))...\"")
        return pending
    }
    
    func enqueueRelayMessage(_ message: Message) -> SDPendingMessage? {
        return enqueuePendingMessage(
            messageID: message.id,
            originID: message.originID,
            destinationID: message.destinationID,
            recipientName: message.destinationID,
            senderName: message.senderName,
            previousHopID: message.previousHopID ?? message.senderID,
            text: message.text,
            channel: message.destinationID,
            isSOS: message.isSOS,
            priorityRaw: message.isSOS ? 2 : 0,
            queueRole: .relay,
            hopsCount: message.hopsCount,
            ttl: message.ttl
        )
    }

    
    func resetFailedPendingMessages() {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let targetStatus = PendingMessageStatus.failed.rawValue
        let descriptor = FetchDescriptor<SDPendingMessage>(
            predicate: #Predicate { $0.statusRaw == targetStatus }
        )
        if let failedItems = try? context.fetch(descriptor), !failedItems.isEmpty {
            for item in failedItems {
                item.status = .queued
                item.retryCount = 0
                item.lastAttemptTimestamp = nil
            }
            saveContext()
            AppLogger.multipeer.info("Reset \(failedItems.count) failed pending messages to QUEUED status for retry on peer reconnect.")
        }
    }
    
    func fetchPendingMessages() -> [SDPendingMessage] {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let now = Date()
        let descriptor = FetchDescriptor<SDPendingMessage>()
        guard let allPending = try? context.fetch(descriptor) else { return [] }
        
        var validPending: [SDPendingMessage] = []
        for item in allPending {
            // Purge expired store-and-forward messages (e.g. older than 7 days)
            if item.expiresAt < now {
                context.delete(item)
                AppLogger.multipeer.info("Purged expired pending message \(item.messageID)")
            } else {
                validPending.append(item)
            }
        }
        saveContext()
        
        // Priority ordering: Emergency SOS first (priorityRaw descending), followed by timestamp order
        return validPending.sorted { first, second in
            if first.priorityRaw != second.priorityRaw {
                return first.priorityRaw > second.priorityRaw
            }
            return first.timestamp < second.timestamp
        }
    }
    
    func updatePendingMessageStatus(messageID: UUID, status: PendingMessageStatus) {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let descriptor = FetchDescriptor<SDPendingMessage>(
            predicate: #Predicate { $0.messageID == messageID }
        )
        if let pending = (try? context.fetch(descriptor))?.first {
            let oldStatus = pending.status.rawValue
            pending.status = status
            pending.lastAttemptTimestamp = Date()
            if status == .failed || status == .sending {
                pending.retryCount += 1
            }
            if status == .failed {
                PinglyTransportDiagnosticsManager.shared.incrementQueueFailed()
            }
            saveContext()
            
            AppLogger.multipeer.info("""
            [PINGLY_QUEUE_STATE]
            messageID=\(messageID.uuidString)
            messageType=\(pending.queueRole.rawValue)
            destination=\(pending.destinationID)
            channel=\(pending.channel)
            oldStatus=\(oldStatus)
            newStatus=\(status.rawValue)
            attempt=\(pending.retryCount)
            retryCount=\(pending.retryCount)
            timestamp=\(Date())
            """)
            
            AppLogger.multipeer.info("Updated pending message \(messageID) status to '\(status.rawValue)' (Attempt \(pending.retryCount))")
        }
    }
    
    func markPendingMessageAsACKed(messageID: UUID) {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        // Mark SDChatMessage as delivered (GREEN)
        let chatDescriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.id == messageID }
        )
        if let chat = (try? context.fetch(chatDescriptor))?.first {
            chat.isDelivered = true
        }
        
        // Mark SDVoiceTranscript as delivered (GREEN)
        let voiceDescriptor = FetchDescriptor<SDVoiceTranscript>(
            predicate: #Predicate { $0.id == messageID }
        )
        if let voice = (try? context.fetch(voiceDescriptor))?.first {
            voice.isDelivered = true
        }
        
        // Delete from pending store-and-forward queue
        let pendingDescriptor = FetchDescriptor<SDPendingMessage>(
            predicate: #Predicate { $0.messageID == messageID }
        )
        if let pendingList = try? context.fetch(pendingDescriptor) {
            for pending in pendingList {
                context.delete(pending)
            }
        }
        
        saveContext()
        
        AppLogger.multipeer.info("""
        [PINGLY_QUEUE_STATE]
        messageID=\(messageID.uuidString)
        messageType=PENDING
        destination=LOCAL
        channel=N/A
        oldStatus=WAITING_FOR_ACK
        newStatus=DELIVERED
        attempt=0
        retryCount=0
        timestamp=\(Date())
        """)
        
        PinglyTransportDiagnosticsManager.shared.incrementQueueDelivered()
        AppLogger.multipeer.info("ACK Received: Marked message \(messageID) as delivered (GREEN) and purged from pending queue.")
    }

    
    func isMessageAlreadyProcessed(messageID: UUID) -> Bool {
        let chatDescriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.id == messageID }
        )
        if (try? context.fetch(chatDescriptor))?.isEmpty == false {
            return true
        }
        let voiceDescriptor = FetchDescriptor<SDVoiceTranscript>(
            predicate: #Predicate { $0.id == messageID }
        )
        if (try? context.fetch(voiceDescriptor))?.isEmpty == false {
            return true
        }
        return false
    }
    
    func deletePendingMessage(_ item: SDPendingMessage) {
        context.delete(item)
        saveContext()
        AppLogger.multipeer.info("Deleted delivered pending message for recipient '\(item.recipientName)'")
    }

    // MARK: - User Profile & Unique Username Persistence
    
    func fetchUserProfile(appleUserID: String) -> SDUserProfile? {
        let descriptor = FetchDescriptor<SDUserProfile>(
            predicate: #Predicate { $0.appleUserID == appleUserID }
        )
        return (try? context.fetch(descriptor))?.first
    }
    
    func findOrCreateUserProfile(appleUserID: String, appleName: String?, email: String?) -> SDUserProfile {
        if let existing = fetchUserProfile(appleUserID: appleUserID) {
            AppLogger.multipeer.info("Retrieved existing profile for Apple User: Username=\(existing.username), AccountID=\(existing.accountID.uuidString)")
            IdentityManager.shared.bindSession(accountID: existing.accountID, username: existing.username, displayName: existing.displayName)
            return existing
        }
        
        // Generate atomic unique 8-character username (guaranteed non-duplicate at DB level)
        var uniqueUsername = ""
        var isUnique = false
        var attempts = 0
        
        while !isUnique && attempts < 100 {
            attempts += 1
            let candidate = UsernameGenerator.generate8CharUsername()
            let checkDescriptor = FetchDescriptor<SDUserProfile>(
                predicate: #Predicate { $0.username == candidate }
            )
            if (try? context.fetch(checkDescriptor))?.isEmpty ?? true {
                uniqueUsername = candidate
                isUnique = true
            }
        }
        
        if uniqueUsername.isEmpty {
            uniqueUsername = "P2P\(UUID().uuidString.prefix(5).uppercased())"
        }
        
        // Determine initial display name: Apple provided name, otherwise unique 8-char username
        let finalDisplayName: String
        if let appleName = appleName, !appleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalDisplayName = appleName.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            finalDisplayName = uniqueUsername
        }
        
        let newAccountID = UUID()
        let newProfile = SDUserProfile(
            accountID: newAccountID,
            appleUserID: appleUserID,
            username: uniqueUsername,
            displayName: finalDisplayName,
            email: email
        )
        
        context.insert(newProfile)
        saveContext()
        
        IdentityManager.shared.bindSession(accountID: newAccountID, username: uniqueUsername, displayName: finalDisplayName)
        AppLogger.multipeer.info("Created NEW user profile: AccountID=\(newAccountID.uuidString), Username=\(uniqueUsername), DisplayName='\(finalDisplayName)'")
        return newProfile
    }


    // MARK: - GDPR Account Deletion Data Purge
    
    /// Atomically purges all user profiles, chat messages, transcripts, and pending messages from SwiftData database
    func purgeAllUserData() {
        do {
            try context.delete(model: SDUserProfile.self)
            try context.delete(model: SDChatMessage.self)
            try context.delete(model: SDPendingMessage.self)
            try context.delete(model: SDVoiceTranscript.self)
            saveContext()
            DispatchQueue.main.async {
                self.totalUnsyncedCount = 0
            }
            AppLogger.multipeer.info("Atomically purged all user profiles, chat messages, transcripts, and pending records from SwiftData store.")
        } catch {
            AppLogger.multipeer.error("Failed to purge SwiftData store during account deletion: \(error.localizedDescription)")
        }
    }




    
    // MARK: - SDNotificationEvent Persistent Deduplication & Event Logging
    
    /// Returns true if a notification with the given deduplicationKey has already been stored
    func isNotificationDeduplicated(deduplicationKey: String) -> Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let descriptor = FetchDescriptor<SDNotificationEvent>(
            predicate: #Predicate { $0.deduplicationKey == deduplicationKey }
        )
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            return true
        }
        return false
    }
    
    /// Atomically records a notification event into SwiftData if not already stored
    @discardableResult
    func recordNotificationEvent(
        eventTypeRaw: String,
        messageID: UUID? = nil,
        peerID: String? = nil,
        title: String,
        body: String,
        deduplicationKey: String
    ) -> Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let descriptor = FetchDescriptor<SDNotificationEvent>(
            predicate: #Predicate { $0.deduplicationKey == deduplicationKey }
        )
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            AppLogger.notifications.info("[Notification] Deduplication hit for key '\(deduplicationKey)'. Skipping record.")
            return false
        }
        
        let event = SDNotificationEvent(
            eventTypeRaw: eventTypeRaw,
            messageID: messageID,
            peerID: peerID,
            timestamp: Date(),
            title: title,
            body: body,
            deliveredToNotificationCenter: true,
            acknowledged: false,
            deduplicationKey: deduplicationKey
        )
        context.insert(event)
        saveContext()
        AppLogger.notifications.info("[Notification] Recorded event '\(eventTypeRaw)' with key '\(deduplicationKey)'")
        return true
    }
    
    /// Fetches all recorded SDNotificationEvents sorted by timestamp descending
    func fetchNotificationEvents() -> [SDNotificationEvent] {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let descriptor = FetchDescriptor<SDNotificationEvent>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
    
    /// Clears all recorded SDNotificationEvents
    func clearNotificationEvents() {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        do {
            try context.delete(model: SDNotificationEvent.self)
            saveContext()
            AppLogger.notifications.info("[Notification] Cleared all persistent notification events.")
        } catch {
            AppLogger.notifications.error("[Notification] Failed to clear notification events: \(error.localizedDescription)")
        }
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
