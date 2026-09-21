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
        conversationID: UUID? = nil,
        isRead: Bool = false
    ) async {
        let tag1 = await AppLogger.messageTag(id)
        let tag = isDelivered ? "\(tag1) REMOTE_PERSIST" : "\(tag1) PERSIST"
        AppLogger.multipeer.info("\(tag)_START type=\(messageTypeRaw)")
        
        guard (messageTypeRaw == "CHAT" || messageTypeRaw == "TEXT"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let resolvedOriginID = originID ?? senderID
        let resolvedDestinationID = destinationID ?? channel
        
        let descriptor = FetchDescriptor<SDChatMessage>(predicate: #Predicate { $0.id == id })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.isDelivered = isDelivered
            existing.isRead = isRead
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
            message.isRead = isRead
            modelContext.insert(message)
        }
        
        do {
            try modelContext.save()
            AppLogger.multipeer.info("\(tag)_SUCCESS type=\(messageTypeRaw)")
        } catch {
            AppLogger.multipeer.error("[MESSAGE_SAVE_FAILED] messageID=\(id.uuidString) reason=\(error.localizedDescription)")
        }
    }
    
    public func markConversationAsRead(conversationID: UUID) {
        let descriptor = FetchDescriptor<SDChatMessage>(predicate: #Predicate { $0.conversationID == conversationID && $0.isRead == false })
        if let unreadMessages = try? modelContext.fetch(descriptor) {
            for message in unreadMessages {
                message.isRead = true
            }
            try? modelContext.save()
        }
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
        relayHistory: [String] = [],
        messageTypeRaw: String = "CHAT"
    ) {
        if messageTypeRaw == "LOCATION_UPDATE" {
            let locDescriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.destinationID == destinationID && $0.messageTypeRaw == "LOCATION_UPDATE" })
            if let existingLoc = try? modelContext.fetch(locDescriptor).first {
                existingLoc.text = text // Update the payload
                existingLoc.timestamp = Date()
                existingLoc.messageID = messageID
                try? modelContext.save()
                return
            }
        }
        
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.messageID == messageID })
        if (try? modelContext.fetch(descriptor).first) != nil {
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
        pending.messageTypeRaw = messageTypeRaw
        
        modelContext.insert(pending)
        try? modelContext.save()
        
        _ = (try? modelContext.fetchCount(FetchDescriptor<SDPendingMessage>())) ?? 0
        _ = (priorityRaw == 2) ? "HIGH" : (priorityRaw == 1 ? "NORMAL" : "LOW")
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
                pending.statusRaw = "DELIVERED"
                pending.deliveredAt = Date()
                pending.lastAttemptTimestamp = Date()
            }
            try? modelContext.save()
        }
        
        try? modelContext.save()
    }
    
    public func updatePendingMessageStatus(messageID: UUID, statusRaw: String, reason: String? = nil) async {
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.messageID == messageID })
        if let pending = (try? modelContext.fetch(descriptor))?.first {
            let oldStatus = pending.statusRaw
            pending.statusRaw = statusRaw
            pending.lastAttemptTimestamp = Date()
            
            if statusRaw == "FAILED" {
                pending.retryCount = max(pending.retryCount + 1, 1)
            }
            try? modelContext.save()
            
            let tag = await AppLogger.messageTag(messageID)
            if let r = reason {
                AppLogger.multipeer.info("\(tag) STATE \(oldStatus) -> \(statusRaw) reason=\(r) retryCount=\(pending.retryCount)")
            } else {
                AppLogger.multipeer.info("\(tag) STATE \(oldStatus) -> \(statusRaw)")
            }
        }
    }
    
    public func deletePendingMessage(messageID: UUID) async {
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.messageID == messageID })
        if let pending = (try? modelContext.fetch(descriptor))?.first {
            modelContext.delete(pending)
            try? modelContext.save()
            let tag = await AppLogger.messageTag(messageID)
            AppLogger.multipeer.info("\(tag) DELETED from queue")
        }
    }
    
    public func cleanupAcknowledgedPendingMessages() {
        let expirationDate = Date().addingTimeInterval(-86400) // 24 hours
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate {
            $0.statusRaw == "ACKNOWLEDGED" && $0.timestamp < expirationDate
        })
        if let pendingList = try? modelContext.fetch(descriptor) {
            for pending in pendingList {
                modelContext.delete(pending)
            }
            if !pendingList.isEmpty {
                try? modelContext.save()
            }
        }
    }
    
    public func resetFailedPendingMessages() {
        let targetStatus = "FAILED"
        let descriptor = FetchDescriptor<SDPendingMessage>(predicate: #Predicate { $0.statusRaw == targetStatus })
        if let failedItems = try? modelContext.fetch(descriptor), !failedItems.isEmpty {
            for item in failedItems {
                item.statusRaw = "QUEUED"
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
    
    public func upsertLocationSessions(_ states: [LocationSessionState]) async {
        for state in states {
            let remotePeerID = state.remotePeerID
            let descriptor = FetchDescriptor<SDLocationShareSession>(predicate: #Predicate { $0.remotePeerID == remotePeerID })
            
            let session: SDLocationShareSession
            if let existing = (try? modelContext.fetch(descriptor))?.first {
                session = existing
            } else {
                let localNodeID = await NodeIdentity.shared.nodeID
                session = SDLocationShareSession(
                    localPeerID: localNodeID,
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
    
    public func updateLocationSessionState(remotePeerID: String, remoteDisplayName: String, stateRaw: String? = nil, isSharingLocal: Bool? = nil, isSharingRemote: Bool? = nil) async {
        let descriptor = FetchDescriptor<SDLocationShareSession>(predicate: #Predicate { $0.remotePeerID == remotePeerID })
        let session: SDLocationShareSession
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            session = existing
        } else {
            let localNodeID = await NodeIdentity.shared.nodeID
            session = SDLocationShareSession(
                localPeerID: localNodeID,
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
    
    // MARK: - Friends Operations
    
    func fetchFriends() -> [SDFriend] {
        let descriptor = FetchDescriptor<SDFriend>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    func getFriendStatus(for nodeID: String) -> FriendStatus {
        let descriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == nodeID })
        return (try? modelContext.fetch(descriptor))?.first?.status ?? .none
    }
    
    func localSendFriendRequest(nodeID: String, displayName: String) -> UUID {
        let requestID = UUID()
        let descriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == nodeID })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.handle = displayName
            existing.status = .requestSent
            existing.requestID = requestID
        } else {
            let newFriend = SDFriend(nodeID: nodeID, handle: displayName, status: .requestSent, requestID: requestID)
            modelContext.insert(newFriend)
        }
        try? modelContext.save()
        return requestID
    }
    
    func handleFriendRequest(from nodeID: String, handle: String, requestID: UUID) {
        let descriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == nodeID })
        if let existing = try? modelContext.fetch(descriptor).first {
            if existing.status == .none {
                existing.status = .requestReceived
                existing.requestID = requestID
                existing.handle = handle
                try? modelContext.save()
            }
        } else {
            let newFriend = SDFriend(nodeID: nodeID, handle: handle, status: .requestReceived, requestID: requestID)
            modelContext.insert(newFriend)
            try? modelContext.save()
        }
    }
    
    func handleFriendAccept(from nodeID: String) {
        let descriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == nodeID })
        if let existing = try? modelContext.fetch(descriptor).first {
            if existing.status == .requestSent || existing.status == .requestReceived {
                existing.status = .accepted
                try? modelContext.save()
            }
        }
    }
    
    func handleFriendDecline(from nodeID: String) {
        let descriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == nodeID })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.status = .declined
            try? modelContext.save()
        }
    }
    
    func removeFriend(nodeID: String) {
        let descriptor = FetchDescriptor<SDFriend>(predicate: #Predicate { $0.nodeID == nodeID })
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }
    
    // MARK: - Channel Protocols
    
    func handleChannelInvite(channelID: String, from nodeID: String) async {
        guard let channelUUID = UUID(uuidString: channelID) else { return }
        
        let localNodeID = await NodeIdentity.shared.nodeID
        let descriptor = FetchDescriptor<SDChannelMember>(
            predicate: #Predicate { $0.channelID == channelUUID && $0.nodeID == localNodeID }
        )
        
        if let existing = try? modelContext.fetch(descriptor).first {
            if existing.statusRaw == "DECLINED" || existing.statusRaw == "REVOKED" {
                existing.statusRaw = "INVITED"
                try? modelContext.save()
            }
        } else {
            let newMember = SDChannelMember(channelID: channelUUID, nodeID: localNodeID, statusRaw: "INVITED")
            modelContext.insert(newMember)
            try? modelContext.save()
        }
    }
    
    func handleChannelAccept(channelID: String, from nodeID: String) {
        guard let channelUUID = UUID(uuidString: channelID) else { return }
        
        let descriptor = FetchDescriptor<SDChannelMember>(
            predicate: #Predicate { $0.channelID == channelUUID && $0.nodeID == nodeID }
        )
        
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.statusRaw = "ACCEPTED"
            existing.joinedAt = Date()
            try? modelContext.save()
        } else {
            // They accepted an invite we didn't know we sent? Or they are joining an open mesh?
            // For now, insert as accepted.
            let newMember = SDChannelMember(channelID: channelUUID, nodeID: nodeID, statusRaw: "ACCEPTED", joinedAt: Date())
            modelContext.insert(newMember)
            try? modelContext.save()
        }
    }
    
    func handleChannelDecline(channelID: String, from nodeID: String) {
        guard let channelUUID = UUID(uuidString: channelID) else { return }
        
        let descriptor = FetchDescriptor<SDChannelMember>(
            predicate: #Predicate { $0.channelID == channelUUID && $0.nodeID == nodeID }
        )
        
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.statusRaw = "DECLINED"
            try? modelContext.save()
        }
    }

    public func performPersistenceReadWriteDiagnosticTest() -> (success: Bool, message: String) {
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
        
        // 2. SAVE
        do {
            try modelContext.save()
        } catch {
            return (false, "SAVE failed: \(error.localizedDescription)")
        }
        
        // 3. FETCH
        let descriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.id == testID }
        )
        guard let fetched = (try? modelContext.fetch(descriptor))?.first else {
            return (false, "FETCH failed: Record not found")
        }
        
        // 4. VERIFY
        guard fetched.text == testText && fetched.senderName == "DiagnosticSystem" else {
            return (false, "VERIFY failed: Record content mismatch")
        }
        
        // 5. DELETE & CLEANUP
        modelContext.delete(fetched)
        do {
            try modelContext.save()
        } catch {
            return (false, "Cleanup failed: \(error.localizedDescription)")
        }
        
        return (true, "All stages passed")
    }
}

