//
//  MeshDiagnosticsView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 14/08/26.
//

import SwiftUI

/// Diagnostic View displaying active peers, pending offline queue states, delivery ACK status, and persistent notification deduplication events
struct MeshDiagnosticsView: View {
    @StateObject private var notificationManager = MeshNotificationManager.shared
    @StateObject private var swiftDataService = SwiftDataService.shared
    @StateObject private var multipeerService = MultipeerService.shared
    
    @State private var notificationEvents: [SDNotificationEvent] = []
    @State private var pendingMessages: [SDPendingMessage] = []
    
    var body: some View {
        Form {
            // Section 1: Notification System & Auth Status
            Section("Notification System Status") {
                HStack {
                    SettingsIconBadge(systemName: "bell.badge.fill", backgroundColor: notificationManager.isAuthorized ? AppTheme.tintColor : .gray)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Authorization Status")
                            .font(.body)
                        Text(notificationManager.isAuthorized ? "Authorized (UNUserNotificationCenter)" : "Not Authorized / Restricted")
                            .font(.caption)
                            .foregroundColor(notificationManager.isAuthorized ? .green : .red)
                    }
                    Spacer()
                    if !notificationManager.isAuthorized {
                        Button("Enable") {
                            notificationManager.requestAuthorization()
                        }
                        .font(.caption.bold())
                    }
                }
                
                Toggle(isOn: $notificationManager.showPreview) {
                    HStack {
                        SettingsIconBadge(systemName: "eye.fill", backgroundColor: .blue)
                        Text("Show Message Previews")
                    }
                }
            }
            
            // Section 2: Notification Preferences
            Section("Event Notification Toggles") {
                Toggle("Message Queued & Received", isOn: $notificationManager.notifyMessages)
                Toggle("Delivery Receipts (ACKs)", isOn: $notificationManager.notifyDelivery)
                Toggle("Nearby Device Discovery", isOn: $notificationManager.notifyPeerDiscovery)
                Toggle("Peer Connection State", isOn: $notificationManager.notifyPeerConnection)
                Toggle("PTT Walkie-Talkie Activity", isOn: $notificationManager.notifyPTT)
                Toggle("Failed & Expired Messages", isOn: $notificationManager.notifyFailedMessages)
                Toggle("Detailed Mesh Diagnostics", isOn: $notificationManager.notifyMeshDiagnostics)
            }
            
            // Section 3: Active Peers & Mesh Routes
            Section("Active Mesh Peers (\(multipeerService.connectedPeers.count))") {
                if multipeerService.connectedPeers.isEmpty {
                    Text("No connected peers in local mesh range")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(multipeerService.connectedPeers) { peer in
                        HStack {
                            Circle()
                                .fill(peer.isConnected ? Color.green : AppTheme.hotMagenta)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.displayName.cleanBaseName)
                                    .font(.system(size: 14, weight: .semibold))
                                Text("ID: \(peer.id)")
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(peer.rssi) dBm")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            // Section 4: Pending Offline Store-and-Forward Queue
            Section("Pending Store-and-Forward Queue (\(pendingMessages.count))") {
                if pendingMessages.isEmpty {
                    Text("No queued offline messages")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(pendingMessages, id: \.id) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(msg.status.rawValue)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(statusColor(msg.status).opacity(0.18))
                                    .foregroundColor(statusColor(msg.status))
                                    .cornerRadius(4)
                                
                                Text("To: \(msg.recipientName)")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(msg.timestamp.logTimeString)
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            Text("\"\(msg.text)\"")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            
                            HStack {
                                Text("Attempts: \(msg.retryCount)/\(msg.maxRetries)")
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("ID: \(msg.messageID.uuidString.prefix(8))")
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            
            // Section 5: Persistent Notification Event Log & Deduplication Keys
            Section {
                if notificationEvents.isEmpty {
                    Text("No persistent notification events recorded")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(notificationEvents, id: \.id) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(event.eventTypeRaw)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.glassTint)
                                    .foregroundColor(AppTheme.tintColor)
                                    .cornerRadius(4)
                                Spacer()
                                Text(event.timestamp.logTimeString)
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            Text(event.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(event.body)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Key: \(event.deduplicationKey)")
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text("Notification Event History (\(notificationEvents.count))")
                    Spacer()
                    if !notificationEvents.isEmpty {
                        Button("Clear") {
                            swiftDataService.clearNotificationEvents()
                            refreshData()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Mesh Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshData()
        }
    }
    
    private func refreshData() {
        notificationEvents = swiftDataService.fetchNotificationEvents()
        pendingMessages = swiftDataService.fetchPendingMessages()
    }
    
    private func statusColor(_ status: PendingMessageStatus) -> Color {
        switch status {
        case .created, .queued: return .orange
        case .transmitting, .relayed: return .blue
        case .sent: return AppTheme.hotMagenta
        case .delivered, .read: return .green
        case .failed, .expired, .cancelled: return .red
        }
    }
}

#Preview {
    NavigationStack {
        MeshDiagnosticsView()
    }
}
