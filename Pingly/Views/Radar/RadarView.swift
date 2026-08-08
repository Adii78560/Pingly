//
//  RadarView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Tactical Proximity Radar screen displaying nearby mesh nodes
struct RadarView: View {
    @StateObject var viewModel: RadarViewModel
    @State private var pulseAnimation = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Constants.UI.Colors.backgroundDark
                    .ignoresSafeArea()
                
                VStack(spacing: Constants.UI.Layout.standardSpacing) {
                    // Header Bar
                    headerView
                    
                    // Radar Display Sweep
                    radarDisplay
                        .padding(.vertical, 8)
                    
                    // Peer List Header
                    HStack {
                        Text("NEARBY NODES (\(viewModel.nearbyPeers.count))")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(Constants.UI.Colors.textSecondary)
                        Spacer()
                        
                        Button(action: {
                            viewModel.toggleScanning()
                        }) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(viewModel.isScanning ? Constants.UI.Colors.primaryAccent : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(viewModel.isScanning ? "SCANNING" : "PAUSED")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(viewModel.isScanning ? Constants.UI.Colors.primaryAccent : Color.gray)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                    
                    // Peer Node List
                    if viewModel.nearbyPeers.isEmpty {
                        emptyStateView
                    } else {
                        peerListView
                    }
                }
            }
            .navigationTitle("Proximity Radar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Constants.UI.Colors.backgroundDark, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("P2P MESH DISCOVERY")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(Constants.UI.Colors.primaryAccent)
                Text("BLE & Local Wi-Fi Radio")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Constants.UI.Colors.textPrimary)
            }
            Spacer()
            
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 22))
                .foregroundColor(viewModel.isScanning ? Constants.UI.Colors.primaryAccent : Color.gray)
        }
        .glassCardStyle()
        .padding(.horizontal)
    }
    
    // MARK: - Radar Visual Sweep
    private var radarDisplay: some View {
        ZStack {
            // Concentric Distance Rings
            ForEach([0.3, 0.6, 0.9], id: \.self) { scale in
                Circle()
                    .stroke(Constants.UI.Colors.primaryAccent.opacity(0.25), lineWidth: 1)
                    .frame(width: Constants.UI.Layout.radarDiameter * scale, height: Constants.UI.Layout.radarDiameter * scale)
            }
            
            // Crosshairs
            Rectangle()
                .fill(Constants.UI.Colors.primaryAccent.opacity(0.15))
                .frame(width: 1, height: Constants.UI.Layout.radarDiameter)
            Rectangle()
                .fill(Constants.UI.Colors.primaryAccent.opacity(0.15))
                .frame(width: Constants.UI.Layout.radarDiameter, height: 1)
            
            // Pulse Wave
            if viewModel.isScanning {
                Circle()
                    .stroke(Constants.UI.Colors.primaryAccent.opacity(0.5), lineWidth: 2)
                    .frame(width: Constants.UI.Layout.radarDiameter, height: Constants.UI.Layout.radarDiameter)
                    .scaleEffect(pulseAnimation ? 1.0 : 0.1)
                    .opacity(pulseAnimation ? 0.0 : 0.8)
                    .onAppear {
                        withAnimation(Constants.UI.Animation.radarPulse) {
                            pulseAnimation = true
                        }
                    }
            }
            
            // Center Local Self Marker
            ZStack {
                Circle()
                    .fill(Constants.UI.Colors.primaryAccent)
                    .frame(width: 16, height: 16)
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: 22, height: 22)
            }
            
            // Nearby Peer Dots plotted around center
            ForEach(Array(viewModel.nearbyPeers.prefix(6).enumerated()), id: \.element.id) { index, peer in
                let angle = Double(index) * (2.0 * .pi / Double(max(viewModel.nearbyPeers.prefix(6).count, 1)))
                let radius = min(CGFloat(peer.estimatedDistanceMeters) * 12.0 + 40, Constants.UI.Layout.radarDiameter / 2.0 - 20)
                let x = cos(angle) * radius
                let y = sin(angle) * radius
                
                Button(action: {
                    viewModel.selectedPeer = peer
                }) {
                    ZStack {
                        Circle()
                            .fill(peer.emergencyStatus.themeColor)
                            .frame(width: 14, height: 14)
                        Circle()
                            .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                    }
                }
                .offset(x: x, y: y)
            }
        }
        .frame(width: Constants.UI.Layout.radarDiameter, height: Constants.UI.Layout.radarDiameter)
    }
    
    // MARK: - Peer Node List
    private var peerListView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.nearbyPeers) { peer in
                    peerCardRow(peer: peer)
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func peerCardRow(peer: PeerDevice) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(peer.emergencyStatus.themeColor.opacity(0.2))
                    .frame(width: 44, height: 44)
                Image(systemName: peer.emergencyStatus.iconName)
                    .foregroundColor(peer.emergencyStatus.themeColor)
                    .font(.system(size: 20))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(peer.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Constants.UI.Colors.textPrimary)
                    Spacer()
                    Text("\(peer.rssi) dBm")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Constants.UI.Colors.primaryAccent)
                }
                
                HStack {
                    Text(peer.emergencyStatus.rawValue)
                        .font(.system(size: 12))
                        .foregroundColor(Constants.UI.Colors.textSecondary)
                    Spacer()
                    Text(String(format: "%.1fm away", peer.estimatedDistanceMeters))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Constants.UI.Colors.textMuted)
                }
            }
        }
        .glassCardStyle()
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 40))
                .foregroundColor(Constants.UI.Colors.textMuted)
            Text("No Nearby Pingly Nodes Detected")
                .font(.headline)
                .foregroundColor(Constants.UI.Colors.textSecondary)
            Text("Ensure Bluetooth and local Wi-Fi are enabled. Scanning for off-grid devices...")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(Constants.UI.Colors.textMuted)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }
}
