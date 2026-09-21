import SwiftData
import Combine
import SwiftUI
import OSLog

@MainActor
public final class ActivityFeedManager: ObservableObject {
    public static let shared = ActivityFeedManager()
    
    @Published public var unreadCount: Int = 0
    
    private var context: ModelContext {
        SwiftDataService.shared.context
    }
    
    private init() {
        refreshUnreadCount()
    }
    
    public func addLocationRequest(peerID: String, displayName: String) {
        let item = SDActivityItem(
            peerID: peerID,
            displayName: displayName,
            typeRaw: "LOCATION_REQUEST",
            statusRaw: "PENDING"
        )
        context.insert(item)
        try? context.save()
        refreshUnreadCount()
    }
    
    public func addLocationStarted(peerID: String, displayName: String) {
        let item = SDActivityItem(
            peerID: peerID,
            displayName: displayName,
            typeRaw: "LOCATION_START",
            statusRaw: "ACCEPTED"
        )
        context.insert(item)
        try? context.save()
        refreshUnreadCount()
    }
    
    public func addEmergencySOS(peerID: String, displayName: String) {
        let item = SDActivityItem(
            peerID: peerID,
            displayName: displayName,
            typeRaw: "EMERGENCY_SOS",
            statusRaw: "CRITICAL"
        )
        context.insert(item)
        try? context.save()
        refreshUnreadCount()
    }
    
    public func markAllAsRead() {
        do {
            let descriptor = FetchDescriptor<SDActivityItem>(predicate: #Predicate { !$0.isRead })
            let unreadItems = try context.fetch(descriptor)
            for item in unreadItems {
                item.isRead = true
            }
            try context.save()
            refreshUnreadCount()
        } catch {
            AppLogger.multipeer.error("Failed to mark activity items as read: \(error.localizedDescription)")
        }
    }
    
    public func updateStatus(for itemID: UUID, newStatus: String) {
        do {
            let descriptor = FetchDescriptor<SDActivityItem>(predicate: #Predicate { $0.id == itemID })
            if let item = try context.fetch(descriptor).first {
                item.statusRaw = newStatus
                try context.save()
            }
        } catch {
            AppLogger.multipeer.error("Failed to update activity status: \(error.localizedDescription)")
        }
    }
    
    public func refreshUnreadCount() {
        do {
            let descriptor = FetchDescriptor<SDActivityItem>(predicate: #Predicate { !$0.isRead })
            unreadCount = try context.fetchCount(descriptor)
        } catch {
            unreadCount = 0
        }
    }
}
