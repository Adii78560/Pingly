//
//  RadarView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

//
//  RadarView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// AirDrop / Find My inspired Proximity Radar View conforming to Apple HIG
struct RadarView: View {
    @StateObject var viewModel: RadarViewModel
    
    @State private var isBreathing = false
    @State private var showEditNameAlert = false
    @State private var newBroadcastNameText = ""
    @State private var showTacticalMap = false
    @State private var showBreadcrumbs = false
    @State private var activeNavTarget: NavigationTarget?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Central AirDrop Pulse Radar Display
                airDropRadarScanner
                    .padding(.top, 10)
                
                // Status Subtitle
                VStack(spacing: 4) {
                    Text(viewModel.isScanning ? "Scanning for nearby devices..." : "Scanning Paused")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    
                    Text("Make sure Wi-Fi & Bluetooth are turned on.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                
                Spacer()
                
                // Discovered Devices Section (AirDrop / Find My Card Tray)
                discoveredPeersSection
                    .padding(.bottom, 12)
            }
            .navigationTitle("Radar")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 12) {
                        Button(action: { showTacticalMap = true }) {
                            Image(systemName: "map.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(AppTheme.tintColor)
                        }
                        
                        Button(action: { showBreadcrumbs = true }) {
                            Image(systemName: "point.filled.topleft.down.curvedto.point.bottomright.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        newBroadcastNameText = viewModel.broadcastName
                        showEditNameAlert = true
                    }) {
                        HStack(spacing: 4) {
                            Text(viewModel.broadcastName)
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(AppTheme.tintColor)
                    }
                }
            }
            .alert("Edit Broadcast Name", isPresented: $showEditNameAlert) {
                TextField("Enter handle", text: $newBroadcastNameText)
                Button("Save") {
                    viewModel.updateBroadcastName(newBroadcastNameText)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This name will be visible to nearby off-grid Relyvo devices.")
            }
            .fullScreenCover(isPresented: $showTacticalMap) {
                NavigationStack {
                    TacticalMapView(onSelectTarget: { target in
                        self.showTacticalMap = false
                        self.activeNavTarget = target
                    })
                    .environmentObject(NavigationViewModel())
                    .navigationTitle("Tactical Map")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Close") { showTacticalMap = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showBreadcrumbs) {
                BreadcrumbTrailView()
            }
            .fullScreenCover(item: $activeNavTarget) { target in
                OfflineNavigationView(target: target)
            }
            .onAppear {
                newBroadcastNameText = viewModel.broadcastName
                withAnimation(Animation.easeInOut(duration: 2.0).repeatForever(autoreverses: false)) {
                    isBreathing = true
                }
            }
        }
    }
    
    // MARK: - Central AirDrop Radar Scanner
    private var airDropRadarScanner: some View {
        let radarRadius: CGFloat = 110 // Overall radius of the radar (220 width/height)
        
        return ZStack {
            // Concentric Radar Distance Rings
            Circle()
                .stroke(AppTheme.ringStrokeGradient.opacity(0.4), lineWidth: 1.5)
                .frame(width: radarRadius * 2, height: radarRadius * 2)
            
            Circle()
                .stroke(AppTheme.ringStrokeGradient.opacity(0.25), lineWidth: 1)
                .frame(width: radarRadius * 1.33, height: radarRadius * 1.33)
                
            Circle()
                .stroke(AppTheme.ringStrokeGradient.opacity(0.15), lineWidth: 1)
                .frame(width: radarRadius * 0.66, height: radarRadius * 0.66)
            
            // 360° Rotational Sweep
            TimelineView(.animation) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate
                // 2.5s cycle = 360 degrees
                let angle = Angle.degrees((now.remainder(dividingBy: 2.5) / 2.5) * 360.0)
                
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [AppTheme.tintColor.opacity(0.0), AppTheme.tintColor.opacity(0.5)]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(90)
                        )
                    )
                    .frame(width: radarRadius * 2, height: radarRadius * 2)
                    .rotationEffect(angle)
            }
            
            // Render Radar Contacts
            let contacts = viewModel.radarContacts(deviceHeading: LocationService.shared.smoothedHeading)
            ForEach(contacts) { contact in
                ZStack {
                    // Outer pulsating freshness ring
                    Circle()
                        .stroke(AppTheme.tintColor, lineWidth: 1)
                        .frame(width: 36, height: 36)
                        .scaleEffect(isBreathing ? 1.2 : 0.8)
                        .opacity(isBreathing ? 0.0 : 0.8)
                    
                    CircularAvatarView(senderAlias: contact.peer.displayName, senderID: contact.peer.id, size: 28)
                }
                .position(
                    x: radarRadius + CGFloat(cos(contact.angle.radians)) * (radarRadius * contact.radiusFraction),
                    y: radarRadius + CGFloat(sin(contact.angle.radians)) * (radarRadius * contact.radiusFraction)
                )
            }
            
            // Center Node ("YOU")
            ZStack {
                Circle()
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                    .frame(width: 64, height: 64)
                    .shadow(color: AppTheme.hotMagenta.opacity(0.2), radius: 10, x: 0, y: 4)
                
                VStack(spacing: 2) {
                    Image(systemName: "wifi")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppTheme.tintColor)
                    
                    Text("YOU")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.primary)
                }
            }
        }
        .frame(width: radarRadius * 2, height: radarRadius * 2)
    }
    // MARK: - Discovered Devices AirDrop Tray
    private var discoveredPeersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NEARBY DEVICES")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                
                Spacer()
                
                Button(action: {
                    viewModel.toggleScanning()
                }) {
                    Text(viewModel.isScanning ? "Pause" : "Resume")
                        .font(.caption.bold())
                        .foregroundColor(AppTheme.tintColor)
                        .padding(.horizontal, 16)
                }
            }
            
            if viewModel.nearbyPeers.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching for nearby devices...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.nearbyPeers) { peer in
                            airDropPeerCard(peer: peer)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    private func airDropPeerCard(peer: PeerDevice) -> some View {
        Button(action: {
            viewModel.connectToPeer(peer)
        }) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(UIColor.secondarySystemGroupedBackground))
                        .frame(width: 60, height: 60)
                        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
                    
                    Text(peer.displayName.initials)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Circle()
                        .stroke(peer.isConnected ? Color.green : AppTheme.hotMagenta, lineWidth: 2)
                        .frame(width: 66, height: 66)
                    
                    let status = viewModel.friendStatus(for: peer.id)
                    if status != .none {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: statusIcon(for: status))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(statusColor(for: status))
                                    .clipShape(Circle())
                                    .shadow(radius: 2)
                            }
                        }
                        .frame(width: 66, height: 66)
                        .offset(x: 4, y: 4)
                    }
                }
                
                VStack(spacing: 2) {
                    Text(peer.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(width: 90)
                    
                    Text("\(peer.rssi) dBm")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        
                    Text(peer.isConnected ? "Connected" : "Discovered")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(peer.isConnected ? .green : AppTheme.hotMagenta)
                }
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
        .contextMenu {
            let status = viewModel.friendStatus(for: peer.id)
            if status == .accepted {
                Button(role: .destructive, action: {
                    viewModel.removeFriend(peer)
                }) {
                    Label("Remove Friend", systemImage: "person.badge.minus")
                }
            } else if status == .requestSent {
                Button(role: .destructive, action: {
                    viewModel.removeFriend(peer)
                }) {
                    Label("Cancel Request", systemImage: "xmark.circle")
                }
            } else if status == .requestReceived {
                Button(action: {
                    viewModel.acceptFriendRequest(peer.id)
                }) {
                    Label("Accept Request", systemImage: "checkmark.circle")
                }
                Button(role: .destructive, action: {
                    viewModel.declineFriendRequest(peer.id)
                }) {
                    Label("Decline Request", systemImage: "xmark.circle")
                }
            } else if status == .declined {
                Button(action: {
                    viewModel.addFriend(peer)
                }) {
                    Label("Add Again", systemImage: "person.badge.plus")
                }
            } else {
                Button(action: {
                    viewModel.addFriend(peer)
                }) {
                    Label("Add Friend", systemImage: "person.badge.plus")
                }
            }
            
            if status == .accepted {
                Button(action: {
                    // Direct message action
                    let convID = DirectConversationID.make(nodeA: NodeIdentity.shared.nodeID, nodeB: peer.id).uuidString
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateToDirectMessage"), object: nil, userInfo: ["conversationID": convID, "peerID": peer.id, "displayName": peer.displayName])
                }) {
                    Label("Message", systemImage: "message")
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    private func statusIcon(for status: FriendStatus) -> String {
        switch status {
        case .accepted: return "person.2.fill"
        case .requestSent: return "arrow.up.right"
        case .requestReceived: return "arrow.down.left"
        case .declined: return "xmark.octagon.fill"
        default: return ""
        }
    }
    
    private func statusColor(for status: FriendStatus) -> Color {
        switch status {
        case .accepted: return .green
        case .requestSent: return .orange
        case .requestReceived: return .blue
        case .declined: return .red
        default: return .clear
        }
    }
}


