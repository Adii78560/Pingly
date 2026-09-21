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
    
    public private(set) var persistenceActor: PersistenceActor!
    
    init(inMemory: Bool = false) {
        
        let schema = Schema([
            SDVoiceTranscript.self,
            SDChatMessage.self,
            SDPendingMessage.self,
            SDUserProfile.self,
            SDNotificationEvent.self,
            SDLocationShareSession.self,
            SDAudioSegment.self,
            SDVoiceMessage.self,
            SDBreadcrumbTrack.self,
            SDBreadcrumbPoint.self,
            SDOfflineMapRegion.self,
            SDFriend.self
        ])

        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        let storeURL = config.url
        let fileManager = FileManager.default
        
        if !inMemory {
            let parentDir = storeURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                do {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    fatalError("[Persistence][CRITICAL] Failed to create Application Support directory: \(error.localizedDescription)")
                }
            } else {
            }
        }
        
        let storeExists = fileManager.fileExists(atPath: storeURL.path)
        var fileSizeString = "0 bytes"
        if storeExists, let attributes = try? fileManager.attributesOfItem(atPath: storeURL.path),
           let fileSize = attributes[.size] as? Int64 {
            fileSizeString = "\(fileSize) bytes"
        }
        
        
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
            self.persistenceActor = PersistenceActor(modelContainer: self.container)
            
            self.isUsingInMemoryFallback = false
            updateUnsyncedCount()
            logAllEntityCounts()
            
            let chatCount = (try? self.context.fetch(FetchDescriptor<SDChatMessage>()))?.count ?? 0
            let transcriptCount = (try? self.context.fetch(FetchDescriptor<SDVoiceTranscript>()))?.count ?? 0
            let pendingCount = (try? self.context.fetch(FetchDescriptor<SDPendingMessage>()))?.count ?? 0
            
            
            RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "Persistence", event: "PERSISTENCE_RESTORE_CHECK", details: "chatCount=\(chatCount) voiceTranscriptCount=\(transcriptCount) pendingMessageCount=\(pendingCount)")
            RelaynTransportDiagnosticsManager.shared.recordPhysicalTestEvent(category: "Persistence", event: "PERSISTENCE_SNAPSHOT", details: "storeExists=\(storeExists) fileSize=\(fileSizeString)")
        } catch {
            
            
            if inMemory {
                fatalError("Critical: Failed to initialize in-memory SwiftData ModelContainer: \(error.localizedDescription)")
            } else {
                fatalError("Critical: Failed to initialize persistent SwiftData ModelContainer. To prevent data corruption or loss, the app will now terminate. Error: \(error.localizedDescription)")
            }
        }
    }
    
    /// Diagnostics helper: Queries and logs counts for all persistent entities in SwiftData
    func logAllEntityCounts() {
        _ = (try? context.fetch(FetchDescriptor<SDChatMessage>()))?.count ?? 0
        _ = (try? context.fetch(FetchDescriptor<SDVoiceTranscript>()))?.count ?? 0
        _ = (try? context.fetch(FetchDescriptor<SDPendingMessage>()))?.count ?? 0
        _ = (try? context.fetch(FetchDescriptor<SDUserProfile>()))?.count ?? 0
        _ = (try? context.fetch(FetchDescriptor<SDNotificationEvent>()))?.count ?? 0
        _ = (try? context.fetch(FetchDescriptor<SDLocationShareSession>()))?.count ?? 0
        
    }
    
    /// Phase 5 Diagnostic: Performs a non-destructive WRITE -> SAVE -> FETCH -> VERIFY -> DELETE cycle to test SwiftData health
    


    
    // MARK: - Voice Transcripts Operations
    
    /// Persists a voice transcript to SwiftData local storage.
    
    
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
            return []
        }
    }
    
    /// Marks pending transcripts for a channel as delivered when peers join.
    
    
    // MARK: - Audio Segments Operations
    
    /// Persists walkie-talkie audio recording metadata to SwiftData local storage.
    
    
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
            return []
        }
    }

    
    // MARK: - Voice Message Operations (Replacing Text Transcripts)
    
    /// Persists a finalized walkie-talkie audio recording note to SwiftData under the channel.
    
    
    /// Fetches all stored voice messages for a specific channel sorted by timestamp.
    func fetchVoiceMessages(for channel: String) -> [VoiceMessage] {
        let normalizedChannel = channel.uppercased()
        let descriptor = FetchDescriptor<SDVoiceMessage>(
            predicate: #Predicate { $0.channelID == normalizedChannel },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        do {
            let records = try context.fetch(descriptor)
            return records.map {
                VoiceMessage(
                    id: $0.id,
                    sessionID: $0.sessionID,
                    channelID: $0.channelID,
                    senderID: $0.senderID,
                    senderAlias: $0.senderAlias,
                    timestamp: $0.timestamp,
                    duration: $0.duration,
                    audioFilePath: $0.audioFilePath,
                    isPlayed: $0.isPlayed,
                    directionRaw: $0.directionRaw,
                    isDelivered: $0.isDelivered
                )
            }
        } catch {
            return []
        }
    }
    
    /// Marks a specific voice message as played/listened.
    
    
    /// Marks all pending voice messages in a channel as delivered.
    

    /// Updates the audioFilePath of an SDVoiceMessage upon successful M4A compression.
    

    // MARK: - Chat Messages Operations
    
    /// Persists a chat or location message to SwiftData local storage.
    
    
    
    
    


    
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
        
        let backgroundContext = ModelContext(container)
        
        let unsyncedTranscripts = (try? backgroundContext.fetch(transcriptDescriptor)) ?? []
        let unsyncedMessages = (try? backgroundContext.fetch(messageDescriptor)) ?? []
        
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
    
    
    
    
    
    

    
    
    
    func fetchPendingMessages() -> [SDPendingMessage] {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        // Ephemeral context to avoid "Unbinding from main queue" runtime warning when called from background tasks
        let backgroundContext = ModelContext(container)
        
        let now = Date()
        let descriptor = FetchDescriptor<SDPendingMessage>()
        guard let allPending = try? backgroundContext.fetch(descriptor) else { return [] }
        
        var validPending: [SDPendingMessage] = []
        for item in allPending {
            // Check Communication Authorization Gate for direct messages
            let isDirectMessage = item.destinationID != "BROADCAST" && !item.channel.hasPrefix("CH-")
            
            var isAuthorized = true
            if isDirectMessage {
                let destID = item.destinationID
                let friendDesc = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == destID })
                if let friend = (try? backgroundContext.fetch(friendDesc))?.first {
                    isAuthorized = (friend.status == .accepted)
                } else {
                    isAuthorized = false // No relationship
                }
            }
            
            // Purge expired store-and-forward messages
            if item.expiresAt < now {
                backgroundContext.delete(item)
                AppLogger.multipeer.info("Purged expired pending message \(item.messageID)")
            } else if !isAuthorized {
                item.statusRaw = "CANCELLED"
                AppLogger.multipeer.warning("Cancelled pending message \(item.messageID) - Unauthorized destination (Status: \(item.statusRaw))")
            } else if item.statusRaw == "QUEUED" || item.statusRaw == "PENDING" || item.statusRaw == "TRANSMITTING" || item.statusRaw == "SENT" || item.statusRaw == "WAITING_FOR_ACK" || item.statusRaw == "DELIVERED" {
                validPending.append(item)
            }
        }
        try? backgroundContext.save()
        
        // Priority ordering: Emergency SOS first (priorityRaw descending), followed by timestamp order
        return validPending.sorted { first, second in
            if first.priorityRaw != second.priorityRaw {
                return first.priorityRaw > second.priorityRaw
            }
            return first.timestamp < second.timestamp
        }
    }
    
    
    
    

    
    func isMessageAlreadyProcessed(messageID: UUID) -> Bool {
        let backgroundContext = ModelContext(container)
        
        let chatDescriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.id == messageID }
        )
        if (try? backgroundContext.fetch(chatDescriptor))?.isEmpty == false {
            return true
        }
        let voiceDescriptor = FetchDescriptor<SDVoiceTranscript>(
            predicate: #Predicate { $0.id == messageID }
        )
        if (try? backgroundContext.fetch(voiceDescriptor))?.isEmpty == false {
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
            try context.delete(model: SDVoiceMessage.self)
            try context.delete(model: SDVoiceTranscript.self)
            try context.delete(model: SDAudioSegment.self)
            try context.delete(model: SDLocationShareSession.self)
            try context.delete(model: SDBreadcrumbTrack.self)
            try context.delete(model: SDBreadcrumbPoint.self)
            try context.delete(model: SDNotificationEvent.self)
            saveContext()
            DispatchQueue.main.async {
                self.totalUnsyncedCount = 0
            }
            AppLogger.multipeer.info("Atomically purged all user profiles, messages, locations, tracks, and notifications from SwiftData store.")
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
        } catch {
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
    
    
    
    func fetchAllLocationShareSessions() -> [SDLocationShareSession] {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let descriptor = FetchDescriptor<SDLocationShareSession>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Friends
    
    func fetchFriends() -> [SDFriend] {
        queueLock.lock()
        defer { queueLock.unlock() }
        let descriptor = FetchDescriptor<SDFriend>()
        return (try? context.fetch(descriptor)) ?? []
    }
    
    func addFriend(nodeID: String, displayName: String) {
        queueLock.lock()
        defer { queueLock.unlock() }
        let descriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == nodeID })
        if let existing = try? context.fetch(descriptor).first {
            existing.handle = displayName
        } else {
            let newFriend = SDFriend(nodeID: nodeID, handle: displayName)
            context.insert(newFriend)
        }
        saveContext()
    }
    
    func removeFriend(nodeID: String) {
        queueLock.lock()
        defer { queueLock.unlock() }
        let descriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == nodeID })
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
            saveContext()
        }
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
