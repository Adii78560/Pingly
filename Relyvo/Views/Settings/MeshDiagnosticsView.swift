//
//  MeshDiagnosticsView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 14/08/26.
//

import SwiftUI
import SwiftData

/// Diagnostic View displaying active peers, pending offline queue states, delivery ACK status, and persistent notification deduplication events
struct MeshDiagnosticsView: View {
    @StateObject private var notificationManager = MeshNotificationManager.shared
    @StateObject private var swiftDataService = SwiftDataService.shared
    @StateObject private var multipeerService = MultipeerService.shared
    @ObservedObject private var transportDiagnostics = RelaynTransportDiagnosticsManager.shared
    @ObservedObject private var compassHapticManager = CompassHapticManager.shared
    
    @State private var notificationEvents: [SDNotificationEvent] = []
    @State private var pendingMessages: [SDPendingMessage] = []
    @State private var diagnosticTestStatus: String? = nil
    @State private var isRunningDiagnosticTest = false
    @State private var loopbackTestSummary: String? = nil
    @State private var isRunningLoopbackTest = false
    
    private var queuedCount: Int {
        pendingMessages.filter { $0.status == .queued || $0.status == .created }.count
    }
    private var waitingForACKCount: Int {
        pendingMessages.filter { $0.status == .sending || $0.status == .waitingForACK || $0.status == .sent || $0.status == .transmitting }.count
    }
    private var failedCount: Int {
        pendingMessages.filter { $0.status == .failed || $0.status == .expired }.count
    }
    private var ackCount: Int {
        transportDiagnostics.ackMatchedCount
    }
    
    private var deviceFingerprint: String {
        let devID = KeychainIdentityService.shared.fetchOrCreateDeviceID().uuidString
        return String(devID.prefix(6))
    }
    
    private var appleAuthSummary: String {
        let authState = AppleSignInManager.shared.authState.rawValue.capitalized
        let appleFingerprint = AppleSignInManager.shared.appleUserID != nil ? String(AppleSignInManager.shared.appleUserID!.prefix(6)) : "None"
        return "State: \(authState) • Fingerprint: \(appleFingerprint)"
    }
    
    private var storeTypeSummary: String {
        return swiftDataService.isUsingInMemoryFallback ? "In-Memory Fallback" : "Persistent SQLite Disk"
    }
    
    private var chatCount: Int {
        (try? swiftDataService.context.fetch(FetchDescriptor<SDChatMessage>()))?.count ?? 0
    }
    
    private var transcriptCount: Int {
        (try? swiftDataService.context.fetch(FetchDescriptor<SDVoiceTranscript>()))?.count ?? 0
    }
    
    private var userCount: Int {
        (try? swiftDataService.context.fetch(FetchDescriptor<SDUserProfile>()))?.count ?? 0
    }
    
    private var locationSessionCount: Int {
        (try? swiftDataService.context.fetch(FetchDescriptor<SDLocationShareSession>()))?.count ?? 0
    }
    
    var body: some View {
        Form {
            // Section 0: Identity & Persistence System Health (Phase 12)
            Section("Identity & SwiftData System Diagnostics") {
                // Identity Diagnostics
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SettingsIconBadge(systemName: "key.fill", backgroundColor: .indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Device Identity")
                                .font(.body.weight(.medium))
                            Text("Exists: True • Fingerprint: \(deviceFingerprint)")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack {
                        SettingsIconBadge(systemName: "person.badge.key.fill", backgroundColor: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Sign-In State")
                                .font(.body.weight(.medium))
                            Text(appleAuthSummary)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
                
                // Persistence Diagnostics
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SettingsIconBadge(systemName: "cylinder.split.1x2.fill", backgroundColor: swiftDataService.isUsingInMemoryFallback ? .orange : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SwiftData Persistent Store")
                                .font(.body.weight(.medium))
                            Text("Status: Initialized • Type: \(storeTypeSummary)")
                                .font(.caption)
                                .foregroundColor(swiftDataService.isUsingInMemoryFallback ? .orange : .secondary)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Entity Counts")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        
                        Text("• Messages: \(chatCount)  • Transcripts: \(transcriptCount)")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                        Text("• Pending Queue: \(pendingMessages.count)  • Users: \(userCount)  • Sessions: \(locationSessionCount)")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
                
                // Read / Write Diagnostic Test Execution Button
                Button(action: {
                    isRunningDiagnosticTest = true
                    HapticsManager.shared.mediumImpact()
                    Task {
                        let result = await swiftDataService.persistenceActor.performPersistenceReadWriteDiagnosticTest()
                        diagnosticTestStatus = result.message
                        isRunningDiagnosticTest = false
                        if result.success {
                            HapticsManager.shared.successFeedback()
                        } else {
                            HapticsManager.shared.errorFeedback()
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                        Text(isRunningDiagnosticTest ? "Running Write/Read Test..." : "Run Persistence Write/Read Test")
                            .font(.subheadline.bold())
                    }
                    .foregroundColor(AppTheme.tintColor)
                }
                .disabled(isRunningDiagnosticTest)
                
                if let status = diagnosticTestStatus {
                    Text(status)
                        .font(.caption.monospaced())
                        .foregroundColor(status.contains("Passed") ? .green : .red)
                        .padding(.top, 2)
                }
            }
            
            // Section 0.5: Messaging Pipeline Diagnostics (End-to-End Pipeline Observability)
            Section("Messaging Pipeline Diagnostics") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Last Outgoing ID:")
                            .font(.caption.bold())
                        Spacer()
                        Text(transportDiagnostics.lastOutgoingMessageID)
                            .font(.caption.monospaced())
                            .foregroundColor(.blue)
                    }
                    HStack {
                        Text("Last Incoming ID:")
                            .font(.caption.bold())
                        Spacer()
                        Text(transportDiagnostics.lastIncomingMessageID)
                            .font(.caption.monospaced())
                            .foregroundColor(.purple)
                    }
                    HStack {
                        Text("Connected Peer:")
                            .font(.caption.bold())
                        Spacer()
                        Text(transportDiagnostics.lastConnectedPeerID)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Last Send Result:")
                            .font(.caption.bold())
                        Spacer()
                        Text(transportDiagnostics.lastSendResult)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Last Receive Result:")
                            .font(.caption.bold())
                        Spacer()
                        Text(transportDiagnostics.lastReceiveResult)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Last Decode Result:")
                            .font(.caption.bold())
                        Spacer()
                        Text(transportDiagnostics.lastDecodeResult)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Last ACK Result:")
                            .font(.caption.bold())
                        Spacer()
                        Text(transportDiagnostics.lastACKResult)
                            .font(.caption.monospaced())
                            .foregroundColor(.green)
                    }
                }
                .padding(.vertical, 2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Queue Status Breakdown")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("QUEUED: \(queuedCount)")
                            .font(.caption2.monospaced().bold())
                            .foregroundColor(.orange)
                        Spacer()
                        Text("WAITING ACK: \(waitingForACKCount)")
                            .font(.caption2.monospaced().bold())
                            .foregroundColor(.blue)
                    }
                    HStack {
                        Text("FAILED: \(failedCount)")
                            .font(.caption2.monospaced().bold())
                            .foregroundColor(.red)
                        Spacer()
                        Text("ACKNOWLEDGED: \(ackCount)")
                            .font(.caption2.monospaced().bold())
                            .foregroundColor(.green)
                    }
                }
                .padding(.vertical, 2)
                
                Button(action: {
                    isRunningLoopbackTest = true
                    Task { @MainActor in
                        let res = await LoopbackTestHarness.shared.runAllLoopbackTests()
                        loopbackTestSummary = "Loopback Suite Result: \(res.passedCount) Passed, \(res.failedCount) Failed\n\n" + res.reportSummary
                        isRunningLoopbackTest = false
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        Text(isRunningLoopbackTest ? "Running Loopback Suite..." : "Run Simulator Loopback Test Suite")
                            .font(.subheadline.bold())
                    }
                    .foregroundColor(.purple)
                }
                .disabled(isRunningLoopbackTest)
                
                if let summary = loopbackTestSummary {
                    Text(summary)
                        .font(.caption2.monospaced())
                        .foregroundColor(summary.contains("0 Failed") ? .green : .orange)
                        .padding(.top, 2)
                }
            }
            
            // Section 0.6: MCSession Connection Health Summary
            Section("MCSession Connection Health") {
                HStack {
                    Text("MCSession State:")
                        .font(.caption.bold())
                    Spacer()
                    Text(transportDiagnostics.currentMCSessionState)
                        .font(.caption.monospaced().bold())
                        .foregroundColor(transportDiagnostics.currentMCSessionState == "CONNECTED" ? .green : .orange)
                }
                HStack {
                    Text("Connected Peers (\(transportDiagnostics.connectedPeersCount)):")
                        .font(.caption.bold())
                    Spacer()
                    Text(transportDiagnostics.connectedPeersList.isEmpty ? "None" : transportDiagnostics.connectedPeersList.map { String($0.prefix(6)) }.joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Reconnects / Disconnects:")
                        .font(.caption.bold())
                    Spacer()
                    Text("\(transportDiagnostics.reconnectCount) / \(transportDiagnostics.disconnectCount)")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                if transportDiagnostics.lastSocketError != "None" {
                    HStack {
                        Text("Last Error:")
                            .font(.caption.bold())
                        Spacer()
                        Text(transportDiagnostics.lastSocketError)
                            .font(.caption2.monospaced())
                            .foregroundColor(.red)
                    }
                }
            }
            
            // Section 0.7: Session Lifecycle Timeline Buffer
            Section("Session Lifecycle Timeline (Recent)") {
                if transportDiagnostics.recentLifecycleEvents.isEmpty {
                    Text("No lifecycle events recorded yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(transportDiagnostics.recentLifecycleEvents.suffix(15).reversed())) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.event)
                                    .font(.caption2.monospaced().bold())
                                    .foregroundColor(.purple)
                                Spacer()
                                Text(event.timestamp.logTimeString)
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            Text("peer=\(String(event.peer.prefix(6))) \(event.details)")
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            
            // Section 0.8: Physical Device Test Summary
            Section("Physical Device Test Summary") {
                HStack {
                    Text("Test Run ID:")
                        .font(.caption.bold())
                    Spacer()
                    Text(transportDiagnostics.testRunID)
                        .font(.caption.monospaced().bold())
                        .foregroundColor(.purple)
                }
                HStack {
                    Text("Device Fingerprint:")
                        .font(.caption.bold())
                    Spacer()
                    Text(String(KeychainIdentityService.shared.fetchOrCreateDeviceID().uuidString.prefix(6)))
                        .font(.caption.monospaced().bold())
                        .foregroundColor(.blue)
                }
                HStack {
                    Text("Messages (Sent/Rx/ACK/Fail):")
                        .font(.caption.bold())
                    Spacer()
                    Text("\(transportDiagnostics.physicalTestMessagesSentCount) / \(transportDiagnostics.physicalTestMessagesReceivedCount) / \(transportDiagnostics.physicalTestMessagesACKedCount) / \(transportDiagnostics.physicalTestMessageFailuresCount)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("PTT (Sessions/Tx/Rx/Drop):")
                        .font(.caption.bold())
                    Spacer()
                    Text("\(transportDiagnostics.physicalTestPTTSessionsCount) / \(transportDiagnostics.physicalTestPTTTxFramesCount) / \(transportDiagnostics.physicalTestPTTRxFramesCount) / \(transportDiagnostics.physicalTestPTTDroppedFramesCount)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
                
                Button(action: {
                    transportDiagnostics.resetPhysicalTestDiagnostics()
                }) {
                    HStack {
                        Image(systemName: "trash.circle.fill")
                        Text("Reset Physical Test Metrics")
                            .font(.caption.bold())
                    }
                    .foregroundColor(.red)
                }
            }
            
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
            Section("Event Notification & Compass Toggles") {
                Toggle("Message Queued & Received", isOn: $notificationManager.notifyMessages)
                Toggle("Delivery Receipts (ACKs)", isOn: $notificationManager.notifyDelivery)
                Toggle("Nearby Device Discovery", isOn: $notificationManager.notifyPeerDiscovery)
                Toggle("Peer Connection State", isOn: $notificationManager.notifyPeerConnection)
                Toggle("PTT Walkie-Talkie Activity", isOn: $notificationManager.notifyPTT)
                Toggle("Failed & Expired Messages", isOn: $notificationManager.notifyFailedMessages)
                Toggle("Detailed Mesh Diagnostics", isOn: $notificationManager.notifyMeshDiagnostics)
                Toggle("Compass Direction Haptics", isOn: $compassHapticManager.enableCompassHaptics)
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
            
            // Section: Offline Location Sharing Sessions
            Section("Offline Location Sharing Sessions") {
                if LocationShareManager.shared.activeSessions.isEmpty {
                    Text("No active location sharing sessions")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(LocationShareManager.shared.activeSessions.values), id: \.id) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(session.remoteDisplayName.cleanBaseName)
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Text(session.stateRaw)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.glassTint)
                                    .foregroundColor(AppTheme.tintColor)
                                    .cornerRadius(4)
                            }
                            HStack {
                                Text("Local Sharing: \(session.isSharingLocal ? "YES" : "NO")")
                                Spacer()
                                Text("Remote Sharing: \(session.isSharingRemote ? "YES" : "NO")")
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            
                            if let lat = session.lastRemoteLatitude, let lon = session.lastRemoteLongitude {
                                Text("Last Remote GPS: \(String(format: "%.4f", lat)), \(String(format: "%.4f", lon)) (Acc: ±\(Int(session.lastRemoteAccuracy ?? 0))m)")
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
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
