//
//  PhysicalValidationHubView.swift
//  Relyvo
//
//  Created by Antigravity on 18/09/26.
//

import SwiftUI
import SwiftData

/// Dedicated Hub for the 10-Phase Physical Validation Campaign
struct PhysicalValidationHubView: View {
    @StateObject private var multipeerService = MultipeerService.shared
    @StateObject private var pttManager = WalkieTalkieNetworkManager.shared
    @StateObject private var logger = PhysicalValidationLogger.shared
    
    @Query private var allFriends: [SDFriend]
    
    private var nodeID: String {
        KeychainIdentityService.shared.fetchOrCreateDeviceID().uuidString
    }
    
    private var handle: String {
        IdentityManager.shared.displayName
    }
    
    var body: some View {
        List {
            Section {
                Button(action: {
                    withAnimation {
                        logger.isOverlayVisible.toggle()
                    }
                }) {
                    HStack {
                        SettingsIconBadge(systemName: "terminal.fill", backgroundColor: logger.isOverlayVisible ? .green : .gray)
                        Text(logger.isOverlayVisible ? "Hide MESH Console Overlay" : "Show MESH Console Overlay")
                            .font(.body.weight(.medium))
                            .foregroundColor(.primary)
                        Spacer()
                        if logger.isOverlayVisible {
                            Image(systemName: "checkmark")
                                .foregroundColor(.green)
                        }
                    }
                }
                
                Text("Enables a floating overlay that intercepts and displays critical [MESH_...] tags anywhere in the app during the physical test.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Campaign Identity")) {
                HStack {
                    Text("Node ID:")
                        .font(.caption.bold())
                    Spacer()
                    Text(nodeID)
                        .font(.caption2.monospaced())
                        .foregroundColor(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                HStack {
                    Text("Handle:")
                        .font(.caption.bold())
                    Spacer()
                    Text(handle)
                        .font(.caption.monospaced())
                        .foregroundColor(.primary)
                }
            }
            
            Section(header: Text("Live Mesh Topology (\(multipeerService.connectedPeers.count))")) {
                if multipeerService.connectedPeers.isEmpty {
                    Text("No connected peers in local mesh range")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(multipeerService.connectedPeers) { peer in
                        PeerRowView(peer: peer, friend: friend(for: peer.id))
                    }
                }
                
                Text("BLOCKED connections will still perform blind relay forwarding for the mesh, but DirectChatGate will drop their direct 1-to-1 packets.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Live PTT Engine Status")) {
                let isTransmitting = pttManager.isFloorLockedBySelf
                let isReceiving = pttManager.activeFloorSenderID != nil && !pttManager.isFloorLockedBySelf
                
                HStack {
                    Text("Engine State:")
                        .font(.caption.bold())
                    Spacer()
                    Text(isTransmitting ? "TRANSMITTING" : (isReceiving ? "RECEIVING" : "IDLE"))
                        .font(.caption.monospaced().bold())
                        .foregroundColor(isTransmitting ? AppTheme.hotMagenta : (isReceiving ? .blue : .gray))
                }
                HStack {
                    Text("Floor Owner:")
                        .font(.caption.bold())
                    Spacer()
                    Text(pttManager.activeFloorSenderID ?? "None")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Physical Validation Hub")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func friend(for targetNodeID: String) -> SDFriend? {
        allFriends.first(where: { $0.nodeID == targetNodeID })
    }
    
    private func statusColor(_ status: FriendStatus?) -> Color {
        switch status ?? .none {
        case .accepted: return .green
        case .requestSent, .requestReceived: return .orange
        case .declined: return .red
        case .none: return .gray
        }
    }
}

struct PeerRowView: View {
    let peer: PeerDevice
    let friend: SDFriend?
    
    var body: some View {
        let isAccepted = friend?.status == .accepted
        
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(peer.isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(peer.displayName)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(peer.rssi) dBm")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("Node ID:")
                    .font(.caption2.bold())
                    .foregroundColor(.secondary)
                Text(String(peer.id.prefix(8)) + "...")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("Friend Status:")
                    .font(.caption2.bold())
                    .foregroundColor(.secondary)
                Text(friend?.status.rawValue.uppercased() ?? "NONE")
                    .font(.caption2.monospaced())
                    .foregroundColor(statusColor)
                
                Spacer()
                
                Text(isAccepted ? "AUTH: OPEN" : "AUTH: BLOCKED")
                    .font(.caption2.monospaced().bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isAccepted ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    )
                    .foregroundColor(isAccepted ? .green : .red)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var statusColor: Color {
        switch friend?.status ?? .none {
        case .accepted: return .green
        case .requestSent, .requestReceived: return .orange
        case .declined: return .red
        case .none: return .gray
        }
    }
}
