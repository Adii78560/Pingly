//
//  RadioCallView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// watchOS Walkie-Talkie & FaceTime Audio inspired View with Channel-Wise Chat Bubbles
struct RadioCallView: View {
    @StateObject var viewModel: RadioCallViewModel
    @State private var isPttPressedVisual = false
    @State private var showingAddChannelAlert = false
    @State private var newChannelInputText = ""
    
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
                            newChannelInputText = ""
                            showingAddChannelAlert = true
                        }) {
                            Label("Create Custom Channel...", systemImage: "plus.circle")
                        }

                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.isConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.selectedChannel)
                                .font(.system(size: 14, weight: .semibold))
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
                        newChannelInputText = ""
                        showingAddChannelAlert = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("New Channel")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                
                // Peer Contact Card
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
                            .frame(width: 48, height: 48)
                        
                        Text(viewModel.connectedPeerName.initials)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.primary)
                        
                        Circle()
                            .stroke(viewModel.isConnected ? Color.green : Color.gray, lineWidth: 2)
                            .frame(width: 52, height: 52)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(viewModel.connectedPeerName)
                            .font(.system(size: 15, weight: .semibold))
                        
                        HStack(spacing: 6) {
                            Text("\(viewModel.connectedPeerRSSI) dBm")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            Button(action: {
                                viewModel.toggleAddedToMessages()
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: viewModel.isAddedToMessages ? "checkmark" : "plus")
                                    Text(viewModel.isAddedToMessages ? "Saved" : "Add")
                                }
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(viewModel.isAddedToMessages ? .green : .blue)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal, 16)
                
                // Central watchOS Walkie-Talkie Yellow PTT Dial
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 135, height: 135)
                    
                    Circle()
                        .fill(viewModel.isPTTPressed ? Color.orange : Color(red: 1.0, green: 0.8, blue: 0.0)) // #FFCC00 Walkie-Talkie Yellow
                        .frame(width: 105, height: 105)
                        .shadow(color: Color.orange.opacity(viewModel.isPTTPressed ? 0.6 : 0.2), radius: 10, x: 0, y: 4)
                    
                    VStack(spacing: 3) {
                        Image(systemName: viewModel.isPTTPressed ? "waveform.and.mic" : "mic.fill")
                            .font(.system(size: 30, weight: .bold))
                        Text(viewModel.isPTTPressed ? "TALKING" : "TALK")
                            .font(.system(size: 12, weight: .black))
                    }
                    .foregroundColor(.black)
                }
                .scaleEffect(isPttPressedVisual || viewModel.isPTTPressed ? 0.94 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPttPressedVisual || viewModel.isPTTPressed)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !viewModel.isPTTPressed {
                                isPttPressedVisual = true
                                viewModel.startTransmittingVoice()
                            }
                        }
                        .onEnded { _ in
                            isPttPressedVisual = false
                            viewModel.stopTransmittingVoice()
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
                                .fill(isActive ? (effectiveLevel > 0.05 ? Color.orange : Color.orange.opacity(0.5)) : Color.gray.opacity(0.3))
                                .frame(width: 4, height: finalHeight)
                        }
                    }
                }
                .frame(height: 28)
                
                // Channel-Wise Voice Transcripts Chat Bubble Stream (Expanded Layout without End Call button)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 13, weight: .bold))
                        
                        Text("TRANSCRIPTS • \(viewModel.selectedChannel)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        Text("\(viewModel.filteredTranscripts.count) messages")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 10) {

                                if viewModel.filteredTranscripts.isEmpty {
                                    VStack(spacing: 6) {
                                        Image(systemName: "waveform.badge.mic")
                                            .font(.system(size: 24))
                                            .foregroundColor(.secondary.opacity(0.6))
                                        Text("No voice transcripts on \(viewModel.selectedChannel) yet.")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.secondary)
                                        Text("Press & hold TALK to broadcast voice.")
                                            .font(.system(size: 11, weight: .regular))
                                            .foregroundColor(.secondary.opacity(0.8))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                                } else {
                                    ForEach(viewModel.filteredTranscripts) { item in
                                        let isMe = (item.speakerName == viewModel.localUserHandle || item.speakerName == "LOCAL_SELF")
                                        
                                        HStack(alignment: .bottom, spacing: 8) {
                                            if isMe { Spacer(minLength: 40) }
                                            
                                            if !isMe {
                                                Circle()
                                                    .fill(Color.blue.opacity(0.2))
                                                    .frame(width: 26, height: 26)
                                                    .overlay(
                                                        Text(item.speakerName.initials)
                                                            .font(.system(size: 10, weight: .bold))
                                                            .foregroundColor(.blue)
                                                    )
                                            }
                                            
                                            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                                                Text(item.speakerName)
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(isMe ? .orange : .secondary)
                                                
                                                Text(item.text)
                                                    .font(.system(size: 13, weight: .regular))
                                                    .foregroundColor(isMe ? .white : .primary)
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 8)
                                                    .background(
                                                        isMe ?
                                                        AnyShapeStyle(LinearGradient(gradient: Gradient(colors: [Color.orange, Color.orange.opacity(0.85)]), startPoint: .topLeading, endPoint: .bottomTrailing)) :
                                                        AnyShapeStyle(Color(UIColor.tertiarySystemGroupedBackground))
                                                    )
                                                    .cornerRadius(14)
                                                
                                                Text(item.timestamp.logTimeString)
                                                    .font(.system(size: 9, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            if isMe {
                                                Circle()
                                                    .fill(Color.orange.opacity(0.2))
                                                    .frame(width: 26, height: 26)
                                                    .overlay(
                                                        Text(item.speakerName.initials)
                                                            .font(.system(size: 10, weight: .bold))
                                                            .foregroundColor(.orange)
                                                    )
                                            }
                                            
                                            if !isMe { Spacer(minLength: 40) }
                                        }
                                        .id(item.id)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onChange(of: viewModel.filteredTranscripts.count) { _ in
                            if let last = viewModel.filteredTranscripts.last {
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
            .navigationTitle("Walkie-Talkie")
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
