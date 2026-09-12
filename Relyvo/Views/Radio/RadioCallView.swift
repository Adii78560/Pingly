//
//  RadioCallView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// watchOS Walkie-Talkie & FaceTime Audio inspired View with Channel-Wise Chat Bubbles
struct RadioCallView: View {
    @StateObject var viewModel: RadioCallViewModel
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var featureAccessManager = FeatureAccessManager.shared
    
    @State private var isPttPressedVisual = false
    @State private var showingAddChannelAlert = false
    @State private var newChannelInputText = ""
    @State private var breathingScale: CGFloat = 1.0
    @State private var breathingOpacity: Double = 0.6
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Active Channel Menu Bar
                HStack {
                    Menu {
                        Section("Walkie-Talkie Channels") {
                            ForEach(viewModel.availableChannels, id: \.self) { ch in
                                Button(action: {
                                    viewModel.selectedChannel = ch
                                }) {
                                    HStack {
                                        Text(ch)
                                        if ch == viewModel.selectedChannel {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        
                        Divider()
                        
                        Button(action: {
                            viewModel.shareActiveChannel()
                        }) {
                            Label("Share \(viewModel.selectedChannel) with Peers", systemImage: "square.and.arrow.up")
                        }
                        
                        Button(action: {
                            featureAccessManager.requireAccess(to: .createChannel) {
                                newChannelInputText = ""
                                showingAddChannelAlert = true
                            }
                        }) {
                            Label(
                                subscriptionManager.isPro ? "Create Custom Channel..." : "Create Custom Channel... (Pro 🔒)",
                                systemImage: subscriptionManager.isPro ? "plus.circle" : "lock.fill"
                            )
                        }

                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.isConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.selectedChannel)
                                .font(.system(size: 14, weight: .semibold))
                            if !viewModel.activeChannelMembers.isEmpty {
                                Text("\(viewModel.activeChannelMembers.count)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.85))
                                    .clipShape(Capsule())
                            }
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(20)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        featureAccessManager.requireAccess(to: .createChannel) {
                            newChannelInputText = ""
                            showingAddChannelAlert = true
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: subscriptionManager.isPro ? "plus" : "lock.fill")
                            Text("New Channel")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AppTheme.tintColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppTheme.glassTint)
                        .cornerRadius(16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                
                // High-Visibility Emergency SOS Beacon Banner
                if let sos = viewModel.activeSOSAlert {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 16, weight: .black))
                                .foregroundColor(.yellow)
                            
                            Text("CRITICAL EMERGENCY SOS")
                                .font(.system(size: 13, weight: .black))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            Button {
                                viewModel.dismissSOSAlert()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        
                        HStack(spacing: 8) {
                            Text("From: \(sos.senderAlias)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                            
                            Text("• \(sos.timestamp.relativeTimeAgo)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        if let loc = sos.distanceAndBearing(from: viewModel.currentLocation) {
                            Text("📍 \(loc.distanceString) • \(loc.bearingString) • \(sos.formattedCoordinates)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                        } else {
                            Text("📍 \(sos.formattedCoordinates)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        
                        HStack {
                            Button {
                                viewModel.tuneToEmergencyChannel()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text("TUNE TO CH-1 EMERGENCY")
                                }
                                .font(.system(size: 12, weight: .black))
                                .foregroundColor(.red)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.white)
                                .cornerRadius(12)
                            }
                            
                            Spacer()
                        }
                        .padding(.top, 2)
                    }
                    .padding(14)
                    .background(
                        LinearGradient(
                            colors: [Color.red, Color.red.opacity(0.88)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(16)
                    .shadow(color: Color.red.opacity(0.5), radius: 10, x: 0, y: 4)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Live Transmitting Banner
                if viewModel.isPTTPressed {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(AppTheme.hotMagenta)
                            .frame(width: 8, height: 8)
                            .scaleEffect(breathingScale)
                        Text("🎙️ Transmitting live on \(viewModel.selectedChannel)...")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(AppTheme.hotMagenta)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(AppTheme.hotMagenta)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppTheme.hotMagenta.opacity(0.12))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Live Active Speaker Banner
                if viewModel.session.isReceivingAudio, let speaker = viewModel.liveActiveSpeaker {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .scaleEffect(breathingScale)
                        Text("🔴 \(speaker) speaking live on \(viewModel.selectedChannel)...")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.red)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // Central watchOS Walkie-Talkie Sunset PTT Dial with Dynamic AirDrop Peer Orbit Ring & Breathing Radar Pulse
                ZStack {
                    let peers = viewModel.channelPeers
                    let peerCount = peers.count
                    let hasPeers = !peers.isEmpty
                    let orbitRadius: CGFloat = 110.0
                    let bubbleSize: CGFloat = peerCount <= 4 ? 44.0 : (peerCount <= 8 ? 34.0 : 26.0)
                    
                    // Animated Breathing Radar Pulse Ring (pulses when no peers on channel, locks static when peers connect)
                    Circle()
                        .stroke(AppTheme.ringStrokeGradient.opacity(hasPeers ? 0.4 : breathingOpacity), lineWidth: hasPeers ? 2 : 3)
                        .frame(width: 135, height: 135)
                        .scaleEffect(hasPeers ? 1.0 : breathingScale)
                        .onAppear {
                            withAnimation(
                                Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                            ) {
                                breathingScale = 1.35
                                breathingOpacity = 0.05
                            }
                        }
                    
                    // AirDrop Peer Orbit Bubbles floating dynamically around PTT button
                    ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                        let angle = (2.0 * .pi * Double(index)) / Double(max(1, peerCount)) - (.pi / 2.0)
                        let offsetX = orbitRadius * CGFloat(cos(angle))
                        let offsetY = orbitRadius * CGFloat(sin(angle))
                        
                        Button {
                            viewModel.addUserToMessages(peer: peer)
                        } label: {
                            VStack(spacing: 2) {
                                ZStack {
                                    Circle()
                                        .fill(AppTheme.primaryGradient)
                                        .frame(width: bubbleSize, height: bubbleSize)
                                        .shadow(color: AppTheme.hotMagenta.opacity(0.4), radius: 6, x: 0, y: 3)
                                    
                                    Text(peer.displayName.prefix(2).uppercased())
                                        .font(.system(size: max(8, bubbleSize * 0.38), weight: .black))
                                        .foregroundColor(.white)
                                }
                                
                                Text(peer.displayName)
                                    .font(.system(size: 9, weight: .bold))
                                    .lineLimit(1)
                                    .foregroundColor(.primary)
                            }
                        }
                        .offset(x: offsetX, y: offsetY)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: peerCount)
                    }
                    
                    Circle()
                        .fill(AppTheme.glassTint)
                        .frame(width: 135, height: 135)
                    
                    Circle()
                        .fill(AppTheme.primaryGradient)
                        .frame(width: 105, height: 105)
                        .shadow(color: AppTheme.hotMagenta.opacity(viewModel.isPTTPressed ? 0.7 : 0.3), radius: viewModel.isPTTPressed ? 16 : 8, x: 0, y: 4)
                    
                    VStack(spacing: 3) {
                        if !subscriptionManager.isPro {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 28, weight: .bold))
                            Text("UNLOCK PRO")
                                .font(.system(size: 11, weight: .black))
                        } else {
                            Image(systemName: viewModel.isPTTPressed ? "waveform.and.mic" : "mic.fill")
                                .font(.system(size: 30, weight: .bold))
                            Text(viewModel.isPTTPressed ? "TRANSMITTING" : (viewModel.session.isReceivingAudio ? "LISTENING" : "HOLD TO TALK"))
                                .font(.system(size: 11, weight: .black))
                        }
                    }
                    .foregroundColor(.white)
                }
                .frame(height: 240)
                .scaleEffect(isPttPressedVisual || viewModel.isPTTPressed ? 0.94 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPttPressedVisual || viewModel.isPTTPressed)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard featureAccessManager.canAccess(.walkieTalkie) else {
                                if !isPttPressedVisual {
                                    isPttPressedVisual = true
                                    featureAccessManager.requireAccess(to: .walkieTalkie)
                                }
                                return
                            }
                            if !viewModel.isPTTPressed {
                                isPttPressedVisual = true
                                viewModel.startTransmittingVoice()
                            }
                        }
                        .onEnded { _ in
                            isPttPressedVisual = false
                            if featureAccessManager.canAccess(.walkieTalkie) {
                                viewModel.stopTransmittingVoice()
                            }
                        }
                )

                
                // Audio Waveform Indicator
                TimelineView(.periodic(from: .now, by: 0.04)) { context in
                    HStack(spacing: 4) {
                        ForEach(0..<16, id: \.self) { index in
                            let isActive = viewModel.isPTTPressed || viewModel.session.isReceivingAudio
                            let rawLevel = CGFloat(viewModel.session.audioLevel)
                            let minHeight: CGFloat = 4.0
                            
                            let center: CGFloat = 7.5
                            let distance = abs(CGFloat(index) - center)
                            let bellFactor = max(0.25, 1.0 - (distance / 8.5))
                            
                            let time = context.date.timeIntervalSinceReferenceDate
                            let waveOscillation = sin(time * 14.0 + Double(index) * 0.65) * 0.35 + 0.65
                            let effectiveLevel = rawLevel > 0.02 ? rawLevel : (isActive ? 0.35 : 0.0)
                            
                            let amplifiedHeight = minHeight + (26.0 * effectiveLevel * bellFactor * CGFloat(waveOscillation))
                            let finalHeight: CGFloat = isActive ? max(minHeight, amplifiedHeight) : minHeight
                            
                            RoundedRectangle(cornerRadius: 2)
                                .fill(isActive ? (effectiveLevel > 0.05 ? AppTheme.hotMagenta : AppTheme.hotMagenta.opacity(0.5)) : Color.gray.opacity(0.3))
                                .frame(width: 4, height: finalHeight)
                        }
                    }
                }
                .frame(height: 28)
                
                // Channel Voice Notes History Stream (Replacing Text Transcripts)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "waveform.badge.mic")
                            .foregroundColor(AppTheme.tintColor)
                            .font(.system(size: 13, weight: .bold))
                        
                        Text("VOICE NOTES • \(viewModel.selectedChannel)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        Text("\(viewModel.voiceMessages.count) notes")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 8) {
                                if viewModel.voiceMessages.isEmpty {
                                    VStack(spacing: 6) {
                                        Image(systemName: "waveform.circle")
                                            .font(.system(size: 28))
                                            .foregroundColor(.secondary.opacity(0.6))
                                        Text("No voice notes on \(viewModel.selectedChannel) yet.")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.secondary)
                                        Text("Press & hold TALK to broadcast live audio.")
                                            .font(.system(size: 11, weight: .regular))
                                            .foregroundColor(.secondary.opacity(0.8))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                                } else {
                                    ForEach(viewModel.voiceMessages) { item in
                                        VoiceMessageBubbleView(message: item)
                                            .id(item.id)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onChange(of: viewModel.voiceMessages.count) {
                            if let last = viewModel.voiceMessages.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .navigationTitle(subscriptionManager.isPro ? "Walkie-Talkie" : "Walkie-Talkie 🔒")
            .alert("Create Custom Channel", isPresented: $showingAddChannelAlert) {
                TextField("Channel Name (e.g. BASECAMP)", text: $newChannelInputText)
                Button("Create") {
                    viewModel.createChannel(named: newChannelInputText)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a unique channel name to broadcast with your mesh team.")
            }
        }
    }
}
