import SwiftUI

/// watchOS Walkie-Talkie & FaceTime Audio inspired View with Channel-Wise Chat Bubbles
struct RadioCallView: View {
    @StateObject var viewModel: RadioCallViewModel
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var featureAccessManager = FeatureAccessManager.shared
    
    @State private var isPttPressedVisual = false
    @State private var isHandsFreeLocked = false
    @State private var showingAddChannelAlert = false
    @State private var newChannelInputText = ""
    @State private var showSOSDialog = false
    @State private var showingQRShare = false
    @State private var showingQRScanner = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 1. Top Channel Presence Card
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .foregroundColor(AppTheme.tintColor)
                    
                    Text("\(viewModel.activeChannelMembers.count) Online on \(viewModel.selectedChannel)")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Circle()
                        .fill(viewModel.activeChannelMembers.count > 0 ? AppTheme.tintColor : Color.gray)
                        .frame(width: 8, height: 8)
                        .scaleEffect(viewModel.activeChannelMembers.count > 0 ? 1.2 : 1.0)
                        .animation(viewModel.activeChannelMembers.count > 0 ? Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default, value: viewModel.activeChannelMembers.count)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
                
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
                    .padding(.bottom, 20)
                }

                // 2. Hero Squircle PTT Transmit Card
                ZStack {
                    let isActiveLocal = viewModel.isPTTPressed || isPttPressedVisual
                    let isRemoteSpeaking = viewModel.session.isReceivingAudio || viewModel.liveActiveSpeaker != nil
                    let idleGradient = LinearGradient(colors: [AppTheme.tintColor, AppTheme.tintColor.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    let lockColor = Color.red.opacity(0.8)
                    let remoteColor = Color.red.opacity(0.6)
                    let transmittingGradient = AppTheme.primaryGradient

                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(isHandsFreeLocked ? AnyShapeStyle(lockColor) : (isActiveLocal ? AnyShapeStyle(transmittingGradient) : (isRemoteSpeaking ? AnyShapeStyle(remoteColor) : AnyShapeStyle(idleGradient))))
                        .frame(height: 195)
                        .shadow(color: isActiveLocal ? AppTheme.hotMagenta.opacity(0.6) : AppTheme.tintColor.opacity(0.35), radius: isActiveLocal ? 16 : 8, x: 0, y: isActiveLocal ? 8 : 4)

                    VStack(spacing: 8) {
                        if isRemoteSpeaking {
                            Text("🔴 \(viewModel.liveActiveSpeaker ?? "Peer") speaking live...")
                                .font(.title3.bold())
                                .foregroundColor(.white)
                                .onTapGesture {
                                    if isHandsFreeLocked {
                                        isHandsFreeLocked = false
                                        isPttPressedVisual = false
                                        viewModel.stopTransmittingVoice()
                                        HapticsManager.shared.lightImpact()
                                    }
                                }
                        } else if isHandsFreeLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.white)
                            Text("TRANSMITTING (LOCKED)")
                                .font(.title3.bold())
                                .foregroundColor(.white)
                            Text("Tap anywhere to stop")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.8))
                        } else if isActiveLocal {
                            Text("Transmitting...")
                                .font(.title3.bold())
                                .foregroundColor(.white)
                            // Audio Waveform
                            TimelineView(.periodic(from: .now, by: 0.04)) { context in
                                HStack(spacing: 4) {
                                    ForEach(0..<12, id: \.self) { index in
                                        let rawLevel = CGFloat(viewModel.session.audioLevel)
                                        let time = context.date.timeIntervalSinceReferenceDate
                                        let wave = sin(time * 14.0 + Double(index) * 0.65) * 0.35 + 0.65
                                        let h = 4.0 + (30.0 * (rawLevel > 0.02 ? rawLevel : 0.2) * CGFloat(wave))
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.white)
                                            .frame(width: 4, height: max(4, h))
                                    }
                                }
                            }
                            .frame(height: 40)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.white)
                            Text("Hold to talk")
                                .font(.title3.bold())
                                .foregroundColor(.white)
                            Text("▲ Slide up to lock")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .highPriorityGesture(
                    TapGesture().onEnded {
                        if isHandsFreeLocked {
                            isHandsFreeLocked = false
                            isPttPressedVisual = false
                            viewModel.stopTransmittingVoice()
                            HapticsManager.shared.lightImpact()
                        }
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard featureAccessManager.canAccess(.walkieTalkie) else {
                                if !isPttPressedVisual {
                                    isPttPressedVisual = true
                                    featureAccessManager.requireAccess(to: .walkieTalkie)
                                }
                                return
                            }
                            let isRemoteSpeaking = viewModel.session.isReceivingAudio || viewModel.liveActiveSpeaker != nil
                            if isRemoteSpeaking { return }

                            if !viewModel.isPTTPressed && !isHandsFreeLocked {
                                isPttPressedVisual = true
                                viewModel.startTransmittingVoice()
                            }

                            if value.translation.height < -60 && !isHandsFreeLocked {
                                isHandsFreeLocked = true
                                HapticsManager.shared.heavyImpact()
                            }
                        }
                        .onEnded { _ in
                            if isHandsFreeLocked {
                                // Do nothing, remain transmitting
                            } else {
                                isPttPressedVisual = false
                                if featureAccessManager.canAccess(.walkieTalkie) {
                                    viewModel.stopTransmittingVoice()
                                }
                            }
                        }
                )

                // 3. Middle Tactical Console
                HStack(spacing: 12) {
                    // Left Column: Channel Selector Button
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
                            Label("Share \(viewModel.selectedChannel) Link", systemImage: "square.and.arrow.up")
                        }
                        Button(action: {
                            DispatchQueue.main.async { showingQRShare = true }
                        }) {
                            Label("Share Channel via QR", systemImage: "qrcode")
                        }
                        Button(action: {
                            DispatchQueue.main.async { showingQRScanner = true }
                        }) {
                            Label("Scan QR to Join", systemImage: "qrcode.viewfinder")
                        }
                        Button(action: {
                            featureAccessManager.requireAccess(to: .createChannel) {
                                DispatchQueue.main.async {
                                    newChannelInputText = ""
                                    showingAddChannelAlert = true
                                }
                            }
                        }) {
                            Label(
                                subscriptionManager.isPro ? "Create Custom Channel..." : "Create Custom Channel... (Pro 🔒)",
                                systemImage: subscriptionManager.isPro ? "plus.circle" : "lock.fill"
                            )
                        }
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(AppTheme.tintColor)
                            Text(viewModel.selectedChannel)
                                .lineLimit(1)
                                .font(.system(size: 14, weight: .semibold))
                            if ChannelKeyStore.shared.key(for: viewModel.selectedChannel) != nil {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(AppTheme.tintColor)
                            }
                            Spacer()
                            Text("\(viewModel.activeChannelMembers.count)")
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppTheme.tintColor.opacity(0.15))
                                .foregroundColor(AppTheme.tintColor)
                                .clipShape(Capsule())
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 54)
                        .frame(maxWidth: .infinity)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .cornerRadius(18)
                    }

                    // Right Column: Emergency SOS Button
                    Button {
                        DispatchQueue.main.async {
                            showSOSDialog = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("SOS")
                                .font(.headline.weight(.black))
                        }
                        .foregroundColor(.white)
                        .frame(height: 54)
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .cornerRadius(18)
                        .shadow(color: Color.red.opacity(0.4), radius: 6, x: 0, y: 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                Spacer()
                
                // 4. Bottom Channel Messages Drawer Preview
                Button {
                    viewModel.showingChatDrawer = true
                } label: {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundColor(AppTheme.tintColor)
                        Text("Channel Messages")
                            .font(.system(size: 14, weight: .semibold))
                        
                        if viewModel.hasUnreadChannelMessages {
                            Circle()
                                .fill(AppTheme.hotMagenta)
                                .frame(width: 8, height: 8)
                                .scaleEffect(1.2)
                                .animation(Animation.easeInOut(duration: 1.0).repeatForever(), value: viewModel.hasUnreadChannelMessages)
                        }
                        
                        Spacer()
                        Image(systemName: "chevron.up")
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(24)
                    .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isHandsFreeLocked {
                    isHandsFreeLocked = false
                    isPttPressedVisual = false
                    viewModel.stopTransmittingVoice()
                    HapticsManager.shared.lightImpact()
                }
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
            .sheet(isPresented: $showSOSDialog) {
                NavigationStack {
                    Form {
                        Section {
                            ForEach(EmergencyStatus.allCases.filter({ $0 != .normal })) { status in
                                Button(action: {
                                    viewModel.triggerEmergencySOS(status: status)
                                    viewModel.triggerEmergencySOSBeacon()
                                    showSOSDialog = false
                                }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: status.iconName)
                                            .font(.title3)
                                            .foregroundColor(status.themeColor)
                                            .frame(width: 28)
                                        
                                        Text(status.rawValue)
                                            .font(.body.weight(.medium))
                                            .foregroundColor(.primary)
                                        
                                        Spacer()
                                        
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Emergency Distress Alert")
                        } footer: {
                            Text("Broadcasting an emergency beacon sends high-priority pings to all nearby Relyvo mesh nodes and triggers an acoustic alarm.")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle("Distress Beacon")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showSOSDialog = false
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingQRShare) {
                ChannelQRShareView(channelID: viewModel.selectedChannel)
            }
            .sheet(isPresented: $showingQRScanner) {
                ChannelQRScannerView { scannedChannel in
                    viewModel.selectedChannel = scannedChannel
                }
            }
            .sheet(isPresented: $viewModel.showingChatDrawer, onDismiss: {
                viewModel.hasUnreadChannelMessages = false
            }) {
                ChannelChatModalView(viewModel: viewModel)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}
