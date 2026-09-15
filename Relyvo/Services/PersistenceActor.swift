import Foundation
import SwiftData
import os

@ModelActor
public final actor PersistenceActor {
    
    // MARK: - Chat & Pending Messages
    
    public func saveChatMessage(
        id: UUID = UUID(),
        originID: String? = nil,
        senderID: String,
        destinationID: String? = nil,
        senderName: String,
        channel: String,
        text: String,
        isDelivered: Bool = false,
        messageTypeRaw: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil,
        accuracy: Double? = nil,
        conversationID: UUID? = nil
    ) {
        let tag = isDelivered ? "\(AppLogger.messageTag(id)) REMOTE_PERSIST" : "\(AppLogger.messageTag(id)) PERSIST"
        AppLogger.multipeer.info("\(tag)_START type=\(messageTypeRaw)")
        
        let resolvedOriginID = originID ?? senderID
        let resolvedDestinationID = destinationID ?? channel
        
        let descriptor = FetchDescriptor<SDChatMessage>(predicate: #Predicate { $0.id == id })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.isDelivered = isDelivered
        } else {
            let message = SDChatMessage(
                id: id,
                originID: resolvedOriginID,
                senderID: senderID,
                destinationID: resolvedDestinationID,
                senderName: senderName,
                channel: channel,
                text: text,
                timestamp: Date(),
                isSynced: false,
                isDelivered: isDelivered,
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                accuracy: accuracy,
                conversationID: conversationID
            )
            message.messageTypeRaw = messageTypeRaw
            modelContext.insert(message)
        }
        
        try? modelContext.save()
        AppLogger.multipeer.info("\(tag)_SUCCESS type=\(messageTypeRaw)")
    }
    
    public func enqueuePendingMessage(
        messageID: UUID,
        originID: String,
        destinationID: String,
        recipientName: String,
        senderName: String,
        previousHopID: String? = nil,
        text: String,
        channel: String,
        isSOS: Bool,
        priorityRaw: Int,
        statusRaw: String,
        queueRoleRaw: String,
        hopsCount: Int,
        ttl: Int,
        conversationID: UUID? = nil,
        relayHistory: [String] = []
    ) {
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.messageID == messageID })
        if let existing = try? modelContext.fetch(descriptor).first {
            return
        }
        
        let pending = SDPendingMessage(
            messageID: messageID,
            originID: originID,
            destinationID: destinationID,
            recipientName: recipientName,
            senderName: senderName,
            previousHopID: previousHopID,
            text: text,
            channel: channel,
            conversationID: conversationID,
            timestamp: Date(),
            isSOS: isSOS,
            priorityRaw: priorityRaw,
            retryCount: 0,
            hopsCount: hopsCount,
            ttl: ttl
        )
        pending.relayHistory = relayHistory
        pending.statusRaw = statusRaw
        pending.queueRoleRaw = queueRoleRaw
        
        modelContext.insert(pending)
        try? modelContext.save()
    }
    
    public func markPendingMessageAsACKed(messageID: UUID) {
        let chatDescriptor = FetchDescriptor<SDChatMessage>(predicate: #Predicate { $0.id == messageID })
        if let chat = (try? modelContext.fetch(chatDescriptor))?.first {
            chat.isDelivered = true
        }
        
        let voiceDescriptor = FetchDescriptor<SDVoiceTranscript>(predicate: #Predicate { $0.id == messageID })
        if let voice = (try? modelContext.fetch(voiceDescriptor))?.first {
            voice.isDelivered = true
        }
        
        let vmDescriptor = FetchDescriptor<SDVoiceMessage>(predicate: #Predicate { $0.id == messageID })
        if let vm = (try? modelContext.fetch(vmDescriptor))?.first {
            vm.isDelivered = true
        }
        
        let pendingDescriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.messageID == messageID })
        if let pendingList = try? modelContext.fetch(pendingDescriptor) {
            for pending in pendingList {
                modelContext.delete(pending)
            }
        }
        
        try? modelContext.save()
    }
    
    public func updatePendingMessageStatus(messageID: UUID, statusRaw: String, reason: String? = nil) {
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.messageID == messageID })
        if let pending = (try? modelContext.fetch(descriptor))?.first {
            let oldStatus = pending.statusRaw
            pending.statusRaw = statusRaw
            pending.lastAttemptTimestamp = Date()
            
            if statusRaw == "FAILED" || statusRaw == "TRANSMITTING" || statusRaw == "SENDING" {
                pending.retryCount += 1
            }
            try? modelContext.save()
            
            let tag = AppLogger.messageTag(messageID)
            if let r = reason {
                AppLogger.multipeer.info("\(tag) STATE \(oldStatus) -> \(statusRaw) reason=\(r) retryCount=\(pending.retryCount)")
            } else {
                AppLogger.multipeer.info("\(tag) STATE \(oldStatus) -> \(statusRaw)")
            }
        }
    }
    
    public func resetFailedPendingMessages() {
        let targetStatus = "FAILED"
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.statusRaw == targetStatus })
        if let failedItems = try? modelContext.fetch(descriptor), !failedItems.isEmpty {
            for item in failedItems {
                item.statusRaw = "QUEUED"
                item.retryCount = 0
                item.lastAttemptTimestamp = nil
            }
            try? modelContext.save()
        }
    }
    
    public func isMessageAlreadyProcessed(messageID: UUID) -> Bool {
        let chatDescriptor = FetchDescriptor<SDChatMessage>(predicate: #Predicate { $0.id == messageID })
        if (try? modelContext.fetch(chatDescriptor))?.isEmpty == false {
            return true
        }
        let voiceDescriptor = FetchDescriptor<SDVoiceTranscript>(predicate: #Predicate { $0.id == messageID })
        if (try? modelContext.fetch(voiceDescriptor))?.isEmpty == false {
            return true
        }
        return false
    }
    
    // MARK: - Voice Transcripts & Segments
    
    public func saveVoiceTranscript(
        id: UUID,
        speakerName: String,
        text: String,
        channel: String,
        isDelivered: Bool,
        sessionID: UUID?
    ) {
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
        modelContext.insert(transcript)
        try? modelContext.save()
    }
    
    public func saveAudioSegment(
        id: UUID,
        sessionID: UUID,
        senderID: String,
        senderName: String,
        channelID: String,
        timestamp: Date,
        duration: Double,
        transcriptText: String?,
        localFileURL: String,
        directionRaw: String
    ) {
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
        modelContext.insert(segment)
        try? modelContext.save()
    }
    
    // MARK: - Location Share Sessions
    
    public func upsertLocationSessions(_ states: [LocationSessionState]) {
        for state in states {
            let remotePeerID = state.remotePeerID
            let descriptor = FetchDescriptor<SDLocationShareSession>(predicate: #Predicate { $0.remotePeerID == remotePeerID })
            
            let session: SDLocationShareSession
            if let existing = (try? modelContext.fetch(descriptor))?.first {
                session = existing
            } else {
                session = SDLocationShareSession(
                    localPeerID: NodeIdentity.shared.nodeID,
                    remotePeerID: remotePeerID,
                    remoteDisplayName: state.remoteDisplayName
                )
                modelContext.insert(session)
            }
            
            session.remoteDisplayName = state.remoteDisplayName
            session.isSharingLocal = state.isSharingLocal
            session.isSharingRemote = state.isSharingRemote
            session.isActive = state.isActive
            session.stateRaw = state.stateRaw
            
            if let lat = state.lastLocalLatitude, let lon = state.lastLocalLongitude {
                session.lastLocalLatitude = lat
                session.lastLocalLongitude = lon
                session.lastLocalAccuracy = state.lastLocalAccuracy
                session.lastLocalTimestamp = state.lastLocalTimestamp ?? Date()
            }
            
            if let lat = state.lastRemoteLatitude, let lon = state.lastRemoteLongitude {
                session.lastRemoteLatitude = lat
                session.lastRemoteLongitude = lon
                session.lastRemoteAccuracy = state.lastRemoteAccuracy
                session.lastRemoteSpeed = state.lastRemoteSpeed
                session.lastRemoteCourse = state.lastRemoteCourse
                session.lastRemoteTimestamp = state.lastRemoteTimestamp ?? Date()
                session.sequenceNumber = state.sequenceNumber
                session.lastRemoteSequenceNumber = state.lastRemoteSequenceNumber
            }
        }
        try? modelContext.save()
    }
    
    public func updateLocationSessionState(remotePeerID: String, remoteDisplayName: String, stateRaw: String? = nil, isSharingLocal: Bool? = nil, isSharingRemote: Bool? = nil) {
        let descriptor = FetchDescriptor<SDLocationShareSession>(predicate: #Predicate { $0.remotePeerID == remotePeerID })
        let session: SDLocationShareSession
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            session = existing
        } else {
            session = SDLocationShareSession(
                localPeerID: NodeIdentity.shared.nodeID,
                remotePeerID: remotePeerID,
                remoteDisplayName: remoteDisplayName
            )
            modelContext.insert(session)
        }
        
        session.remoteDisplayName = remoteDisplayName
        if let stateRaw = stateRaw { session.stateRaw = stateRaw }
        if let isSharingLocal = isSharingLocal { session.isSharingLocal = isSharingLocal }
        if let isSharingRemote = isSharingRemote { session.isSharingRemote = isSharingRemote }
        
        try? modelContext.save()
    }
    
    // MARK: - Notifications
    
    public func isNotificationDeduplicated(deduplicationKey: String) -> Bool {
        let descriptor = FetchDescriptor<SDNotificationEvent>(predicate: #Predicate { $0.deduplicationKey == deduplicationKey })
        return (try? modelContext.fetch(descriptor))?.isEmpty == false
    }
    
    public func recordNotificationEvent(
        eventTypeRaw: String,
        messageID: UUID?,
        peerID: String?,
        title: String,
        body: String,
        deduplicationKey: String
    ) {
        if isNotificationDeduplicated(deduplicationKey: deduplicationKey) { return }
        
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
        modelContext.insert(event)
        try? modelContext.save()
    }
    
    // MARK: - Voice Message Operations
    
    public func saveVoiceMessage(
        id: UUID = UUID(),
        sessionID: UUID,
        channelID: String,
        senderID: String,
        senderAlias: String,
        timestamp: Date = Date(),
        duration: Double,
        audioFilePath: String,
        directionRaw: String = "SENDER",
        isDelivered: Bool = true
    ) {
        let normalizedChannel = channelID.uppercased()
        let vm = SDVoiceMessage(
            id: id,
            sessionID: sessionID,
            channelID: normalizedChannel,
            senderID: senderID,
            senderAlias: senderAlias,
            timestamp: timestamp,
            duration: duration,
            audioFilePath: audioFilePath,
            isPlayed: false,
            directionRaw: directionRaw,
            isDelivered: isDelivered
        )
        modelContext.insert(vm)
        try? modelContext.save()
    }
    
    public func markVoiceMessageAsPlayed(id: UUID) {
        let descriptor = FetchDescriptor<SDVoiceMessage>(
            predicate: #Predicate { $0.id == id }
        )
        if let record = try? modelContext.fetch(descriptor).first {
            record.isPlayed = true
            try? modelContext.save()
        }
    }
    
    public func markVoiceMessagesAsDelivered(for channel: String) {
        let normalizedChannel = channel.uppercased()
        let descriptor = FetchDescriptor<SDVoiceMessage>(
            predicate: #Predicate { $0.channelID == normalizedChannel && !$0.isDelivered }
        )
        if let records = try? modelContext.fetch(descriptor) {
            for r in records {
                r.isDelivered = true
            }
            try? modelContext.save()
        }
    }
    
    public func updateVoiceMessageFilePath(sessionID: UUID, newPath: String) {
        let descriptor = FetchDescriptor<SDVoiceMessage>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        if let record = try? modelContext.fetch(descriptor).first {
            record.audioFilePath = newPath
            try? modelContext.save()
        }
    }
    
    public func markTranscriptsAsDelivered(for channel: String) {
        let targetChannel = channel.uppercased()
        let descriptor = FetchDescriptor<SDVoiceTranscript>(
            predicate: #Predicate { $0.channel == targetChannel && !$0.isDelivered }
        )
        if let results = try? modelContext.fetch(descriptor) {
            for item in results {
                item.isDelivered = true
            }
            try? modelContext.save()
        }
    }

    public func performPersistenceReadWriteDiagnosticTest() -> (success: Bool, message: String) {
        AppLogger.multipeer.info("[PersistenceTest] Test started")
        let testID = UUID()
        let testText = "[DIAGNOSTIC_TEST_\(testID.uuidString.prefix(6))]"
        
        let testMessage = SDChatMessage(
            id: testID,
            originID: "DIAGNOSTIC",
            senderID: "DIAGNOSTIC",
            destinationID: "DIAGNOSTIC",
            senderName: "DiagnosticSystem",
            channel: "DIAGNOSTIC_CHANNEL",
            text: testText,
            timestamp: Date(),
            isSynced: true,
            isDelivered: true,
            messageType: .chat
        )
        
        // 1. WRITE
        modelContext.insert(testMessage)
        AppLogger.multipeer.info("[PersistenceTest] Test record created")
        
        // 2. SAVE
        do {
            try modelContext.save()
            AppLogger.multipeer.info("[PersistenceTest] Save succeeded")
        } catch {
            AppLogger.multipeer.error("[PersistenceTest][ERROR] TEST FAILED at SAVE stage: \(error.localizedDescription)")
            return (false, "SAVE failed: \(error.localizedDescription)")
        }
        
        // 3. FETCH
        let descriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.id == testID }
        )
        guard let fetched = (try? modelContext.fetch(descriptor))?.first else {
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
        modelContext.delete(fetched)
        do {
            try modelContext.save()
            AppLogger.multipeer.info("[PersistenceTest] Cleanup succeeded")
        } catch {
            return (false, "Cleanup failed: \(error.localizedDescription)")
        }
        
        return (true, "All stages passed")
    }
}

