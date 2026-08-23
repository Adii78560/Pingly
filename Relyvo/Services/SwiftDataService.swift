//
//  SwiftDataService.swift
//  Relayn
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
    @Published private(set) var isUsingInMemoryFallback: Bool = false
    
    init(inMemory: Bool = false) {
        AppLogger.multipeer.info("[Persistence] App launch detected (inMemory=\(inMemory))")
        AppLogger.multipeer.info("[Persistence] Starting SwiftData initialization")
        
        let schema = Schema([
            SDVoiceTranscript.self,
            SDChatMessage.self,
            SDPendingMessage.self,
            SDUserProfile.self,
            SDNotificationEvent.self,
            SDLocationShareSession.self,
            SDAudioSegment.self
        ])
        AppLogger.multipeer.info("[Persistence] Model schema loaded (7 entities registered)")

        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        let storeURL = config.url
        let fileManager = FileManager.default
        
        if !inMemory {
            let parentDir = storeURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                AppLogger.multipeer.info("[Persistence] Application Support directory missing. Creating directory: \(parentDir.path)")
                do {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
                    AppLogger.multipeer.info("[Persistence] Application Support directory creation succeeded")
                } catch {
                    AppLogger.multipeer.error("[Persistence][ERROR] Application Support directory creation failed: \(error.localizedDescription)")
                    fatalError("[Persistence][CRITICAL] Failed to create Application Support directory: \(error.localizedDescription)")
                }
            } else {
                AppLogger.multipeer.info("[Persistence] Application Support directory verified existing")
            }
        }
        
        let storeExists = fileManager.fileExists(atPath: storeURL.path)
        var fileSizeString = "0 bytes"
        if storeExists, let attributes = try? fileManager.attributesOfItem(atPath: storeURL.path),
           let fileSize = attributes[.size] as? Int64 {
            fileSizeString = "\(fileSize) bytes"
        }
        
        AppLogger.multipeer.info("[Persistence] Persistent store location = \(storeURL.path)")
        AppLogger.multipeer.info("[Persistence] Persistent store URL exists = \(storeExists)")
        AppLogger.multipeer.info("[Persistence] Persistent store file size = \(fileSizeString)")
        AppLogger.multipeer.info("[Persistence] Existing persistent store detected = \(storeExists)")
        AppLogger.multipeer.info("[Persistence] ModelContainer creation started")
        
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
            AppLogger.multipeer.info("[Persistence] ModelContainer creation succeeded")
            AppLogger.multipeer.info("[Persistence] ModelContext created")
            AppLogger.multipeer.info("[Persistence] Container instance created")
            AppLogger.multipeer.info("[Persistence] Container configuration = isStoredInMemoryOnly: false")
            AppLogger.multipeer.info("[Persistence] Store type = persistent")
            AppLogger.multipeer.info("[Persistence] Store URL = \(storeURL.path)")
            AppLogger.multipeer.info("[Persistence] Existing store = \(storeExists)")
            AppLogger.multipeer.info("[Persistence] SwiftData initialization completed")
            
            self.isUsingInMemoryFallback = false
            updateUnsyncedCount()
            logAllEntityCounts()
            
            let chatCount = (try? self.context.fetch(FetchDescriptor<SDChatMessage>()))?.count ?? 0
            let transcriptCount = (try? self.context.fetch(FetchDescriptor<SDVoiceTranscript>()))?.count ?? 0
            let pendingCount = (try? self.context.fetch(FetchDescriptor<SDPendingMessage>()))?.count ?? 0
            
            RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "Persistence", event: "PERSISTENCE_RESTORE_CHECK", details: "chatCount=\(chatCount) voiceTranscriptCount=\(transcriptCount) pendingMessageCount=\(pendingCount)")
            RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "Persistence", event: "PERSISTENCE_SNAPSHOT", details: "storeExists=\(storeExists) fileSize=\(fileSizeString)")
        } catch {
            AppLogger.multipeer.error("[Persistence][ERROR] ModelContainer initialization failed")
            AppLogger.multipeer.error("[Persistence][ERROR] Error = \(error.localizedDescription)")
            AppLogger.multipeer.error("[Persistence][ERROR] Full error description = \(String(describing: error))")
            
            // Non-destructive fallback: Initialize in-memory container to allow app runtime startup while preserving disk files safely on disk
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                self.container = try ModelContainer(for: schema, configurations: [fallbackConfig])
                self.isUsingInMemoryFallback = true
                AppLogger.multipeer.warning("[Persistence] Container instance created (FALLBACK)")
                AppLogger.multipeer.warning("[Persistence] Store type = in-memory")
                AppLogger.multipeer.warning("[Persistence] SwiftData ModelContainer operating in non-destructive fallback mode. Disk store files preserved untouched.")
                updateUnsyncedCount()
                logAllEntityCounts()
            } catch {
                AppLogger.multipeer.error("[Persistence][ERROR] Critical: Failed to initialize fallback SwiftData ModelContainer: \(error.localizedDescription)")
                fatalError("Critical: Failed to initialize fallback SwiftData ModelContainer: \(error.localizedDescription)")
            }
        }
    }
    
    /// Diagnostics helper: Queries and logs counts for all persistent entities in SwiftData
    func logAllEntityCounts() {
        let chatCount = (try? context.fetch(FetchDescriptor<SDChatMessage>()))?.count ?? 0
        let transcriptCount = (try? context.fetch(FetchDescriptor<SDVoiceTranscript>()))?.count ?? 0
        let pendingCount = (try? context.fetch(FetchDescriptor<SDPendingMessage>()))?.count ?? 0
        let userCount = (try? context.fetch(FetchDescriptor<SDUserProfile>()))?.count ?? 0
        let notificationCount = (try? context.fetch(FetchDescriptor<SDNotificationEvent>()))?.count ?? 0
        let locationSessionCount = (try? context.fetch(FetchDescriptor<SDLocationShareSession>()))?.count ?? 0
        
        AppLogger.multipeer.info("[Persistence] Message count = \(chatCount)")
        AppLogger.multipeer.info("[Persistence] Voice transcript count = \(transcriptCount)")
        AppLogger.multipeer.info("[Persistence] Pending message count = \(pendingCount)")
        AppLogger.multipeer.info("[Persistence] User count = \(userCount)")
        AppLogger.multipeer.info("[Persistence] Notification event count = \(notificationCount)")
        AppLogger.multipeer.info("[Persistence] Location share session count = \(locationSessionCount)")
    }
    
    /// Phase 5 Diagnostic: Performs a non-destructive WRITE -> SAVE -> FETCH -> VERIFY -> DELETE cycle to test SwiftData health
    @discardableResult
    func performPersistenceReadWriteDiagnosticTest() -> (success: Bool, message: String) {
        AppLogger.multipeer.info("[PersistenceTest] Test started")
        let testID = UUID()
        let testText = "[DIAGNOSTIC_TEST_\(testID.uuidString.prefix(6))]"
        
        let testMessage = SDChatMessage(
            id: testID,
            senderName: "DiagnosticSystem",
            channel: "DIAGNOSTIC_CHANNEL",
            text: testText,
            timestamp: Date(),
            isSynced: true,
            isDelivered: true
        )
        
        // 1. WRITE
        context.insert(testMessage)
        AppLogger.multipeer.info("[PersistenceTest] Test record created")
        
        // 2. SAVE
        do {
            try context.save()
            AppLogger.multipeer.info("[PersistenceTest] Save succeeded")
        } catch {
            AppLogger.multipeer.error("[PersistenceTest][ERROR] TEST FAILED at SAVE stage: \(error.localizedDescription)")
            return (false, "SAVE failed: \(error.localizedDescription)")
        }
        
        // 3. FETCH
        let descriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.id == testID }
        )
        guard let fetched = (try? context.fetch(descriptor))?.first else {
            AppLogger.multipeer.error("[PersistenceTest][ERROR] TEST FAILED at FETCH stage: Record not found")
            return (false, "FETCH failed: Record not found")
        }
        AppLogger.multipeer.info("[PersistenceTest] Fetch succeeded")
        
        // 4. VERIFY
        guard fetched.text == testText && fetched.senderName == "DiagnosticSystem" else {
            AppLogger.multipeer.error("[PersistenceTest][ERROR] TEST FAILED at VERIFY stage: Data mismatch")
            return (false, "VERIFY failed: Record content mismatch")
        }
        AppLogger.multipeer.info("[PersistenceTest] Record verification succeeded")
        
        // 5. DELETE & CLEANUP
        context.delete(fetched)
        do {
            try context.save()
            AppLogger.multipeer.info("[PersistenceTest] Cleanup succeeded")
        } catch {
            AppLogger.multipeer.error("[PersistenceTest][ERROR] TEST FAILED at CLEANUP stage: \(error.localizedDescription)")
            return (false, "CLEANUP failed: \(error.localizedDescription)")
        }
        
        AppLogger.multipeer.info("[PersistenceTest] TEST PASSED")
        return (true, "SwiftData Read/Write Test Passed Successfully")
    }


    
    // MARK: - Voice Transcripts Operations
    
    /// Persists a voice transcript to SwiftData local storage.
    func saveVoiceTranscript(id: UUID = UUID(), speakerName: String, text: String, channel: String, isDelivered: Bool = false, sessionID: UUID? = nil) -> SDVoiceTranscript {
        let tag = isDelivered ? "\(AppLogger.messageTag(id)) REMOTE_PERSIST" : "\(AppLogger.messageTag(id)) PERSIST"
        AppLogger.multipeer.info("\(tag)_START type=voiceTranscript")
        let transcript = SDVoiceTranscript(
            id: id,
            speakerName: speakerName,
            text: text,
            channel: channel,
            timestamp: Date(),
            isSynced: false,
            isDelivered: isDelivered,
            sessionID: sessionID
        )
        context.insert(transcript)
        saveContext()
        updateUnsyncedCount()
        AppLogger.multipeer.info("\(tag)_SUCCESS type=voiceTranscript")
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
    
    // MARK: - Audio Segments Operations
    
    /// Persists walkie-talkie audio recording metadata to SwiftData local storage.
    func saveAudioSegment(
        id: UUID = UUID(),
        sessionID: UUID,
        senderID: String,
        senderName: String,
        channelID: String,
        timestamp: Date = Date(),
        duration: Double,
        transcriptText: String? = nil,
        localFileURL: String,
        directionRaw: String
    ) -> SDAudioSegment {
        let segment = SDAudioSegment(
            id: id,
            sessionID: sessionID,
            senderID: senderID,
            senderName: senderName,
            channelID: channelID,
            timestamp: timestamp,
            duration: duration,
            transcriptText: transcriptText,
            localFileURL: localFileURL,
            directionRaw: directionRaw
        )
        context.insert(segment)
        saveContext()
        AppLogger.audio.info("[PINGLY_AUDIO_PERSIST] SAVE sessionID=\(sessionID) file=\(localFileURL)")
        AppLogger.audio.info("[PINGLY_AUDIO_PERSIST] SUCCESS sessionID=\(sessionID)")
        return segment
    }
    
    /// Fetches all stored audio segments for a specific channel sorted by timestamp.
    func fetchAudioSegments(for channel: String) -> [SDAudioSegment] {
        let targetChannel = channel.uppercased()
        let descriptor = FetchDescriptor<SDAudioSegment>(
            predicate: #Predicate { $0.channelID == targetChannel },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLogger.audio.error("Failed to fetch audio segments for \(channel): \(error.localizedDescription)")
            return []
        }
    }

    
    // MARK: - Chat Messages Operations
    
    /// Persists a chat or location message to SwiftData local storage.
    func saveChatMessage(
        id: UUID = UUID(),
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
        let tag = isDelivered ? "\(AppLogger.messageTag(id)) REMOTE_PERSIST" : "\(AppLogger.messageTag(id)) PERSIST"
        AppLogger.multipeer.info("\(tag)_START type=\(messageType.rawValue)")
        let message = SDChatMessage(
            id: id,
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
        AppLogger.multipeer.info("\(tag)_SUCCESS type=\(messageType.rawValue)")
        AppLogger.multipeer.info("Persisted Chat Message (Type: \(messageType.rawValue), Delivered: \(isDelivered)): [\(channel)] \(senderName): \"\(text)\"")
        return message
    }
    
    @discardableResult
    func saveMessage(_ msg: Message) -> SDChatMessage {
        return saveChatMessage(
            id: msg.id,
            senderName: msg.senderName,
            channel: msg.destinationID,
            text: msg.text,
            isDelivered: true,
            messageType: msg.type,
            latitude: msg.latitude,
            longitude: msg.longitude,
            altitude: msg.altitude,
            accuracy: msg.accuracy
        )
    }
    
    @discardableResult
    func savePendingMessage(
        messageID: UUID,
        originID: String,
        destinationID: String,
        recipientName: String,
        senderName: String,
        text: String,
        channel: String
    ) -> SDPendingMessage? {
        return enqueuePendingMessage(
            messageID: messageID,
            originID: originID,
            destinationID: destinationID,
            recipientName: recipientName,
            senderName: senderName,
            text: text,
            channel: channel
        )
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
    
    func updatePendingMessageStatus(messageID: UUID, status: PendingMessageStatus, reason: String? = nil) {
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
                RelaynTransportDiagnosticsManager.shared.incrementQueueFailed()
            }
            saveContext()
            
            let tag = AppLogger.messageTag(messageID)
            if let r = reason {
                AppLogger.multipeer.info("\(tag) STATE \(oldStatus) -> \(status.rawValue) reason=\(r) retryCount=\(pending.retryCount)")
            } else {
                AppLogger.multipeer.info("\(tag) STATE \(oldStatus) -> \(status.rawValue)")
            }
            
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
        
        AppLogger.multipeer.info("\(AppLogger.messageTag(messageID)) STATE WAITING_FOR_ACK -> ACKNOWLEDGED")
        
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
        
        RelaynTransportDiagnosticsManager.shared.incrementQueueDelivered()
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

    // MARK: - SDLocationShareSession Persistence Helpers
    
    func fetchLocationShareSession(remotePeerID: String) -> SDLocationShareSession? {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let descriptor = FetchDescriptor<SDLocationShareSession>(
            predicate: #Predicate { $0.remotePeerID == remotePeerID }
        )
        return (try? context.fetch(descriptor))?.first
    }
    
    @discardableResult
    func updateLocationShareSession(
        remotePeerID: String,
        remoteDisplayName: String,
        isSharingLocal: Bool? = nil,
        isSharingRemote: Bool? = nil,
        lastLocalLat: Double? = nil,
        lastLocalLon: Double? = nil,
        lastLocalAcc: Double? = nil,
        lastRemoteLat: Double? = nil,
        lastRemoteLon: Double? = nil,
        lastRemoteAcc: Double? = nil,
        lastRemoteSpeed: Double? = nil,
        lastRemoteCourse: Double? = nil,
        lastRemoteSeq: Int? = nil,
        stateRaw: String? = nil
    ) -> SDLocationShareSession {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let localNodeID = NodeIdentity.shared.nodeID
        let descriptor = FetchDescriptor<SDLocationShareSession>(
            predicate: #Predicate { $0.remotePeerID == remotePeerID }
        )
        let session: SDLocationShareSession
        if let existing = (try? context.fetch(descriptor))?.first {
            session = existing
        } else {
            session = SDLocationShareSession(
                localPeerID: localNodeID,
                remotePeerID: remotePeerID,
                remoteDisplayName: remoteDisplayName
            )
            context.insert(session)
        }
        
        session.remoteDisplayName = remoteDisplayName
        if let val = isSharingLocal { session.isSharingLocal = val }
        if let val = isSharingRemote { session.isSharingRemote = val }
        if let lat = lastLocalLat, let lon = lastLocalLon {
            session.lastLocalLatitude = lat
            session.lastLocalLongitude = lon
            session.lastLocalAccuracy = lastLocalAcc
            session.lastLocalTimestamp = Date()
        }
        if let lat = lastRemoteLat, let lon = lastRemoteLon {
            session.lastRemoteLatitude = lat
            session.lastRemoteLongitude = lon
            session.lastRemoteAccuracy = lastRemoteAcc
            session.lastRemoteSpeed = lastRemoteSpeed
            session.lastRemoteCourse = lastRemoteCourse
            session.lastRemoteTimestamp = Date()
            session.sequenceNumber += 1
        }
        if let seq = lastRemoteSeq {
            session.lastRemoteSequenceNumber = seq
        }
        if let state = stateRaw { session.stateRaw = state }
        saveContext()
        AppLogger.location.info("[LocationSession] Updated session for '\(remoteDisplayName)' (\(remotePeerID)): LocalSharing=\(session.isSharingLocal), RemoteSharing=\(session.isSharingRemote), State=\(session.stateRaw)")
        return session
    }
    
    func fetchAllLocationShareSessions() -> [SDLocationShareSession] {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let descriptor = FetchDescriptor<SDLocationShareSession>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    
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
