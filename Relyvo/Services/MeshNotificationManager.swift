//
//  MeshNotificationManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 14/08/26.
//

import Foundation
import UserNotifications
import Combine
import SwiftUI
import os

/// Enum representing the 13 required notification event categories for the offline mesh transport
public enum MeshNotificationCategory: String, CaseIterable {
    case messageQueued = "MESSAGE_QUEUED"
    case messageSent = "MESSAGE_SENT"
    case messageDelivered = "MESSAGE_DELIVERED"
    case messageReceived = "MESSAGE_RECEIVED"
    case peerDiscovered = "PEER_DISCOVERED"
    case peerConnected = "PEER_CONNECTED"
    case peerDisconnected = "PEER_DISCONNECTED"
    case messageRelayed = "MESSAGE_RELAYED"
    case messageFailed = "MESSAGE_FAILED"
    case messageExpired = "MESSAGE_EXPIRED"
    case meshNetworkAvailable = "MESH_NETWORK_AVAILABLE"
    case meshNetworkLost = "MESH_NETWORK_LOST"
    case pttActivity = "PTT_ACTIVITY"
}

/// Central, thread-safe Notification & Delivery Status Manager for Relayn off-grid mesh network
public final class MeshNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    
    public static let shared = MeshNotificationManager()
    
    // MARK: - Notification Preferences (UserDefaults)
    @AppStorage("pref_notify_messages") public var notifyMessages: Bool = true
    @AppStorage("pref_notify_delivery") public var notifyDelivery: Bool = true
    @AppStorage("pref_notify_peer_discovery") public var notifyPeerDiscovery: Bool = true
    @AppStorage("pref_notify_peer_connection") public var notifyPeerConnection: Bool = true
    @AppStorage("pref_notify_mesh_diagnostics") public var notifyMeshDiagnostics: Bool = false
    @AppStorage("pref_notify_ptt") public var notifyPTT: Bool = true
    @AppStorage("pref_notify_failed_messages") public var notifyFailedMessages: Bool = true
    @AppStorage("pref_show_message_preview") public var showPreview: Bool = true
    
    // MARK: - State & Throttling
    @Published public private(set) var isAuthorized: Bool = false
    
    private let center = UNUserNotificationCenter.current()
    private let lock = NSLock()
    
    // Throttling: Peer Discovery Cooldown (30s)
    private var lastPeerDiscoveredTimestamp: [String: Date] = [:]
    private let discoveryCooldownSeconds: TimeInterval = 30.0
    
    // Grace Period: Peer Disconnection (10s timer)
    private var pendingDisconnectionTimers: [String: Timer] = [:]
    private let disconnectionGracePeriodSeconds: TimeInterval = 10.0
    
    // Active connection tracking to prevent duplicate CONNECTED alerts
    private var activeConnectedSessions: Set<String> = []
    
    private override init() {
        super.init()
        center.delegate = self
        configureCategories()
        checkAuthorizationStatus()
    }
    
    // MARK: - Setup & Authorization
    
    /// Requests UNUserNotificationCenter authorization for local offline notifications
    public func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                if let error = error {
                    AppLogger.notifications.error("[Notification] Authorization request failed: \(error.localizedDescription)")
                } else {
                    AppLogger.notifications.info("[Notification] Authorization status granted=\(granted)")
                }
                completion?(granted)
            }
        }
    }
    
    /// Checks current UNUserNotificationCenter authorization status
    public func checkAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.isAuthorized = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
                AppLogger.notifications.info("[Notification] Checked authorization status: \(settings.authorizationStatus.rawValue)")
            }
        }
    }
    
    /// Configures the 13 notification categories with actions
    private func configureCategories() {
        var categories: Set<UNNotificationCategory> = []
        
        for categoryType in MeshNotificationCategory.allCases {
            let viewAction = UNNotificationAction(
                identifier: "VIEW_ACTION",
                title: "View",
                options: [.foreground]
            )
            let category = UNNotificationCategory(
                identifier: categoryType.rawValue,
                actions: [viewAction],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
            categories.insert(category)
        }
        
        center.setNotificationCategories(categories)
        AppLogger.notifications.info("[Notification] Configured \(categories.count) UNNotificationCategories.")
    }
    
    // MARK: - Core Notification Delivery Engine
    
    /// Posts a local notification if authorized, enabled, and deduplicated
    public func postNotification(
        category: MeshNotificationCategory,
        title: String,
        body: String,
        deduplicationKey: String,
        messageID: UUID? = nil,
        peerID: String? = nil,
        userInfo: [String: Any] = [:]
    ) {
        guard isCategoryEnabled(category) else {
            AppLogger.notifications.info("[Notification] Category '\(category.rawValue)' is disabled in settings. Skipping key '\(deduplicationKey)'.")
            return
        }
        
        // 1. Thread-safe SwiftData Deduplication Check
        let alreadyStored = SwiftDataService.shared.isNotificationDeduplicated(deduplicationKey: deduplicationKey)
        guard !alreadyStored else {
            AppLogger.notifications.info("[Notification] Deduplication hit for key '\(deduplicationKey)'. Suppressing notification.")
            return
        }
        
        // 2. Persist event to SwiftData
        SwiftDataService.shared.recordNotificationEvent(
            eventTypeRaw: category.rawValue,
            messageID: messageID,
            peerID: peerID,
            title: title,
            body: body,
            deduplicationKey: deduplicationKey
        )
        
        // 3. Build UNNotificationRequest
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = (category == .pttActivity) ? nil : .default
        content.categoryIdentifier = category.rawValue
        
        var payloadInfo = userInfo
        payloadInfo["category"] = category.rawValue
        payloadInfo["deduplicationKey"] = deduplicationKey
        if let msgID = messageID { payloadInfo["messageID"] = msgID.uuidString }
        if let pID = peerID { payloadInfo["peerID"] = pID }
        content.userInfo = payloadInfo
        
        let request = UNNotificationRequest(
            identifier: deduplicationKey,
            content: content,
            trigger: nil // Immediate delivery
        )
        
        center.add(request) { error in
            if let error = error {
                AppLogger.notifications.error("[Notification] Failed to deliver UNNotificationRequest '\(deduplicationKey)': \(error.localizedDescription)")
            } else {
                AppLogger.notifications.info("[Notification] Successfully posted local notification '\(category.rawValue)' with key '\(deduplicationKey)'")
            }
        }
    }
    
    private func isCategoryEnabled(_ category: MeshNotificationCategory) -> Bool {
        switch category {
        case .messageQueued, .messageSent, .messageReceived:
            return notifyMessages
        case .messageDelivered:
            return notifyDelivery
        case .peerDiscovered:
            return notifyPeerDiscovery
        case .peerConnected, .peerDisconnected:
            return notifyPeerConnection
        case .messageRelayed, .meshNetworkAvailable, .meshNetworkLost:
            return notifyMeshDiagnostics
        case .messageFailed, .messageExpired:
            return notifyFailedMessages
        case .pttActivity:
            return notifyPTT
        }
    }
    
    // MARK: - Specialized Event Trigger Dispatchers
    
    /// 1. MESSAGE_QUEUED: Message queued waiting for a route
    public func notifyMessageQueued(messageID: UUID, recipientName: String, totalQueuedCount: Int = 1) {
        let title: String
        let body: String
        let dedupKey: String
        
        if totalQueuedCount > 1 {
            title = "Messages Queued"
            body = "\(totalQueuedCount) messages queued waiting for a route to \(recipientName)."
            dedupKey = "QUEUED_BATCH_\(totalQueuedCount)_\(Date().timeIntervalSince1970 / 60.0)"
        } else {
            title = "Message Queued"
            body = "Waiting for a route to \(recipientName)."
            dedupKey = "\(messageID.uuidString)_QUEUED"
        }
        
        postNotification(
            category: .messageQueued,
            title: title,
            body: body,
            deduplicationKey: dedupKey,
            messageID: messageID
        )
    }
    
    /// 2. MESSAGE_SENT: Message sent to next confirmed delivery path
    public func notifyMessageSent(messageID: UUID, recipientName: String) {
        postNotification(
            category: .messageSent,
            title: "Message Sent",
            body: "Your message was sent to \(recipientName).",
            deduplicationKey: "\(messageID.uuidString)_SENT",
            messageID: messageID
        )
    }
    
    /// 3. MESSAGE_DELIVERED: Recipient confirmed receipt via DELIVERY_ACK
    public func notifyMessageDelivered(messageID: UUID, recipientName: String) {
        postNotification(
            category: .messageDelivered,
            title: "Message Delivered",
            body: "\(recipientName) received your message.",
            deduplicationKey: "\(messageID.uuidString)_DELIVERED",
            messageID: messageID
        )
    }
    
    /// 4. MESSAGE_RECEIVED: Incoming message for recipient
    public func notifyMessageReceived(messageID: UUID, senderName: String, textPreview: String) {
        let body = showPreview ? textPreview : "New off-grid message"
        postNotification(
            category: .messageReceived,
            title: "New Message from \(senderName)",
            body: body,
            deduplicationKey: "\(messageID.uuidString)_RECEIVED",
            messageID: messageID
        )
    }
    
    /// 5. PEER_DISCOVERED: Nearby peer discovered with 30s throttling cooldown
    public func notifyPeerDiscovered(peerID: String, displayName: String) {
        lock.lock()
        let now = Date()
        if let lastTime = lastPeerDiscoveredTimestamp[peerID], now.timeIntervalSince(lastTime) < discoveryCooldownSeconds {
            lock.unlock()
            AppLogger.notifications.info("[Peer] Throttling PEER_DISCOVERED notification for '\(displayName)' (\(peerID)). Last seen \(now.timeIntervalSince(lastTime))s ago.")
            return
        }
        lastPeerDiscoveredTimestamp[peerID] = now
        lock.unlock()
        
        let timeWindow = Int(now.timeIntervalSince1970 / 300.0) // 5 min dedup window
        postNotification(
            category: .peerDiscovered,
            title: "Nearby Device Found",
            body: "\(displayName) is nearby.",
            deduplicationKey: "\(peerID)_DISCOVERED_\(timeWindow)",
            peerID: peerID
        )
    }
    
    /// 6. PEER_CONNECTED: Established mesh connection (Cancels pending disconnection timer)
    public func notifyPeerConnected(peerID: String, displayName: String) {
        lock.lock()
        // Cancel pending grace period timer if peer re-connected
        if let timer = pendingDisconnectionTimers[peerID] {
            timer.invalidate()
            pendingDisconnectionTimers.removeValue(forKey: peerID)
            AppLogger.notifications.info("[Peer] Peer '\(displayName)' re-connected within grace period. Cancelled disconnection alert.")
        }
        
        let sessionKey = "\(peerID)_CONNECTED"
        if activeConnectedSessions.contains(sessionKey) {
            lock.unlock()
            return
        }
        activeConnectedSessions.insert(sessionKey)
        lock.unlock()
        
        postNotification(
            category: .peerConnected,
            title: "Connected to \(displayName)",
            body: "Off-grid mesh connection established.",
            deduplicationKey: sessionKey,
            peerID: peerID
        )
    }
    
    /// 7. PEER_DISCONNECTED: Disconnected with 10s grace period
    public func notifyPeerDisconnected(peerID: String, displayName: String) {
        lock.lock()
        pendingDisconnectionTimers[peerID]?.invalidate()
        
        let timer = Timer.scheduledTimer(withTimeInterval: disconnectionGracePeriodSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self.activeConnectedSessions.remove("\(peerID)_CONNECTED")
            self.pendingDisconnectionTimers.removeValue(forKey: peerID)
            self.lock.unlock()
            
            let timeWindow = Int(Date().timeIntervalSince1970 / 600.0)
            self.postNotification(
                category: .peerDisconnected,
                title: "Peer Disconnected",
                body: "\(displayName) is no longer in mesh range.",
                deduplicationKey: "\(peerID)_DISCONNECTED_\(timeWindow)",
                peerID: peerID
            )
        }
        pendingDisconnectionTimers[peerID] = timer
        lock.unlock()
    }
    
    /// 8. MESSAGE_RELAYED: Relayed through intermediate mesh node
    public func notifyMessageRelayed(messageID: UUID, hopCount: Int) {
        postNotification(
            category: .messageRelayed,
            title: "Message Relayed",
            body: "Relayed through mesh (Hop \(hopCount)).",
            deduplicationKey: "\(messageID.uuidString)_RELAYED_\(hopCount)",
            messageID: messageID
        )
    }
    
    /// 9. MESSAGE_FAILED: Failed delivery after max retries
    public func notifyMessageFailed(messageID: UUID, recipientName: String) {
        postNotification(
            category: .messageFailed,
            title: "Message Failed",
            body: "Could not deliver message to \(recipientName).",
            deduplicationKey: "\(messageID.uuidString)_FAILED",
            messageID: messageID
        )
    }
    
    /// 10. MESSAGE_EXPIRED: Expired pending message
    public func notifyMessageExpired(messageID: UUID, recipientName: String) {
        postNotification(
            category: .messageExpired,
            title: "Message Expired",
            body: "Message to \(recipientName) expired after maximum retention.",
            deduplicationKey: "\(messageID.uuidString)_EXPIRED",
            messageID: messageID
        )
    }
    
    /// 11. MESH_NETWORK_AVAILABLE: Route recovered
    public func notifyMeshNetworkAvailable(peerCount: Int) {
        let timeWindow = Int(Date().timeIntervalSince1970 / 300.0)
        postNotification(
            category: .meshNetworkAvailable,
            title: "Mesh Network Available",
            body: "\(peerCount) nearby mesh route(s) connected. Queued messages will transmit.",
            deduplicationKey: "MESH_AVAIL_\(timeWindow)"
        )
    }
    
    /// 12. MESH_NETWORK_LOST: All routes lost
    public func notifyMeshNetworkLost() {
        let timeWindow = Int(Date().timeIntervalSince1970 / 300.0)
        postNotification(
            category: .meshNetworkLost,
            title: "Mesh Network Unavailable",
            body: "No active mesh peers nearby. Messages will be queued.",
            deduplicationKey: "MESH_LOST_\(timeWindow)"
        )
    }
    
    /// 13. PTT_ACTIVITY: Incoming Walkie-Talkie voice stream start
    public func notifyPTTActivity(channel: String, speakerName: String) {
        let timeWindow = Int(Date().timeIntervalSince1970 / 30.0) // 30s dedup
        postNotification(
            category: .pttActivity,
            title: "Walkie-Talkie Audio",
            body: "\(speakerName) is talking on \(channel).",
            deduplicationKey: "PTT_\(speakerName)_\(channel)_\(timeWindow)"
        )
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Foreground presentation handling
        AppLogger.notifications.info("[Notification] Presenting foreground notification '\(notification.request.identifier)'")
        completionHandler([.banner, .sound, .list])
    }
    
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        AppLogger.notifications.info("[Notification] User tapped notification response '\(response.actionIdentifier)': \(userInfo)")
        completionHandler()
    }
}
