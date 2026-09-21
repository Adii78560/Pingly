import SwiftUI
import SwiftData
import CoreLocation

struct ActivityFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \SDActivityItem.timestamp, order: .reverse) private var activityItems: [SDActivityItem]
    @ObservedObject private var locationShareManager = LocationShareManager.shared
    @State private var targetForNavigation: NavigationTarget?
    @State private var showOfflineNavigationView = false
    
    var activeSessions: [LocationSessionState] {
        locationShareManager.activeSessions.values.filter { $0.isSharingLocal || $0.isSharingRemote }.sorted { $0.remoteDisplayName < $1.remoteDisplayName }
    }
    
    var pendingItems: [SDActivityItem] {
        activityItems.filter { $0.typeRaw == "LOCATION_REQUEST" && $0.statusRaw == "PENDING" }
    }
    
    var recentItems: [SDActivityItem] {
        activityItems.filter { !($0.typeRaw == "LOCATION_REQUEST" && $0.statusRaw == "PENDING") }
    }
    
    var body: some View {
        NavigationStack {
            List {
                if activeSessions.isEmpty && pendingItems.isEmpty && recentItems.isEmpty {
                    emptyStateView
                } else {
                    if !activeSessions.isEmpty {
                        Section("Active Location Sharing") {
                            ForEach(activeSessions) { session in
                                activeSessionRow(session: session)
                            }
                        }
                    }
                    
                    if !pendingItems.isEmpty {
                        Section("Pending Requests") {
                            ForEach(pendingItems) { item in
                                ActivityFeedRow(item: item)
                            }
                        }
                    }
                    
                    if !recentItems.isEmpty {
                        Section("Recent Activity") {
                            ForEach(recentItems) { item in
                                ActivityFeedRow(item: item)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                ActivityFeedManager.shared.markAllAsRead()
            }
            .fullScreenCover(isPresented: $showOfflineNavigationView) {
                if let target = targetForNavigation {
                    OfflineNavigationView(target: target)
                }
            }
        }
    }
    
    private func activeSessionRow(session: LocationSessionState) -> some View {
        HStack(spacing: 12) {
            CircularAvatarView(senderAlias: session.remoteDisplayName, senderID: session.remotePeerID, size: 40)
            
            VStack(alignment: .leading, spacing: 4) {
                if session.isSharingLocal && session.isSharingRemote {
                    Text("Mutual Location Sharing Active")
                        .font(.system(size: 15, weight: .semibold))
                } else if session.isSharingRemote {
                    Text("\(session.remoteDisplayName) is sharing location with you")
                        .font(.system(size: 15, weight: .semibold))
                } else if session.isSharingLocal {
                    Text("Sharing your location with \(session.remoteDisplayName)")
                        .font(.system(size: 15, weight: .semibold))
                }
                
                if session.isSharingRemote, let lat = session.lastRemoteLatitude, let lon = session.lastRemoteLongitude, let userCoord = LocationService.shared.currentCoordinate {
                    let distMeters = OfflineNavigationService.shared.calculateDistance(from: userCoord, to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    let formattedDist = OfflineNavigationService.shared.formatDistance(meters: distMeters)
                    Text("📍 \(formattedDist) away")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if session.isSharingRemote {
                Button(action: {
                    if let lat = session.lastRemoteLatitude, let lon = session.lastRemoteLongitude {
                        targetForNavigation = NavigationTarget(
                            id: session.remotePeerID,
                            displayName: session.remoteDisplayName,
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            timestamp: session.lastRemoteTimestamp ?? Date()
                        )
                        showOfflineNavigationView = true
                    }
                }) {
                    Text("Find")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.green))
                }
                .buttonStyle(.plain)
            } else if session.isSharingLocal {
                Button(action: {
                    LocationShareManager.shared.stopSharingLocation(with: session.remotePeerID, displayName: session.remoteDisplayName)
                }) {
                    Text("Stop")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var emptyStateView: some View {
        Section {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "bell.slash")
                    .font(.system(size: 48))
                    .foregroundColor(Color(UIColor.systemGray3))
                Text("No Recent Activity")
                    .font(.headline)
                Text("When friends send requests or share location, it will appear here.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
        .listRowBackground(Color.clear)
    }
}

struct ActivityFeedRow: View {
    let item: SDActivityItem
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CircularAvatarView(senderAlias: item.displayName, senderID: item.peerID, size: 40)
            
            VStack(alignment: .leading, spacing: 6) {
                if item.typeRaw == "EMERGENCY_SOS" {
                    Text("\(item.displayName) triggered an Emergency SOS!")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.red)
                } else {
                    Text(item.typeRaw == "LOCATION_REQUEST" ? "\(item.displayName) requested your offline GPS location" : "\(item.displayName) started sharing location")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                }
                
                Text(item.timestamp.formatted())
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if item.typeRaw == "LOCATION_REQUEST" {
                    if item.statusRaw == "PENDING" {
                        HStack(spacing: 12) {
                            Button(action: {
                                LocationShareManager.shared.respondToLocationRequest(from: item.peerID, displayName: item.displayName, accept: true)
                                ActivityFeedManager.shared.updateStatus(for: item.id, newStatus: "ACCEPTED")
                            }) {
                                Text("Share Location")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(Color.green))
                            }
                            
                            Button(action: {
                                LocationShareManager.shared.respondToLocationRequest(from: item.peerID, displayName: item.displayName, accept: false)
                                ActivityFeedManager.shared.updateStatus(for: item.id, newStatus: "DECLINED")
                            }) {
                                Text("Decline")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(Color(UIColor.systemGray5)))
                            }
                        }
                        .padding(.top, 4)
                        .buttonStyle(PlainButtonStyle())
                    } else {
                        Text(item.statusRaw.capitalized)
                            .font(.caption)
                            .bold()
                            .foregroundColor(item.statusRaw == "ACCEPTED" ? .green : .secondary)
                            .padding(.top, 2)
                    }
                } else if item.typeRaw == "EMERGENCY_SOS" {
                    Text("EMERGENCY")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .cornerRadius(4)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
