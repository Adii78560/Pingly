//
//  RadarView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

//
//  RadarView.swift
//  Pingly
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
                        .foregroundColor(.orange)
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
                Text("This name will be visible to nearby off-grid Pingly devices.")
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
        ZStack {
            // Concentric AirDrop Breathing Pulse Rings
            Circle()
                .stroke(Color.orange.opacity(0.4), lineWidth: 1.5)
                .frame(width: 200, height: 200)
                .scaleEffect(isBreathing ? 1.3 : 1.0)
                .opacity(isBreathing ? 0.0 : 0.5)
            
            Circle()
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                .frame(width: 150, height: 150)
                .scaleEffect(isBreathing ? 1.18 : 0.95)
                .opacity(isBreathing ? 0.1 : 0.4)
            
            // Center Node ("YOU")
            ZStack {
                Circle()
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                    .frame(width: 96, height: 96)
                    .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
                
                VStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.orange)
                    
                    Text("YOU")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.primary)
                }
            }
        }
        .frame(height: 220)
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
                        .foregroundColor(.orange)
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
                        .stroke(peer.isConnected ? Color.green : Color.orange, lineWidth: 2)
                        .frame(width: 66, height: 66)
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
                }
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }

}


