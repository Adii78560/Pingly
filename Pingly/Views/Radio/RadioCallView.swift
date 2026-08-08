//
//  RadioCallView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Off-Grid Push-To-Talk (PTT) Radio Call Interface
struct RadioCallView: View {
    @StateObject var viewModel: RadioCallViewModel
    @State private var waveAnimation = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Constants.UI.Colors.backgroundDark
                    .ignoresSafeArea()
                
                VStack(spacing: 24) {
                    // Channel Selector Header
                    channelHeaderCard
                        .padding(.horizontal)
                        .padding(.top, 12)
                    
                    Spacer()
                    
                    // Waveform & Speaker Status
                    speakerStatusView
                    
                    Spacer()
                    
                    // Push-To-Talk Holding Button
                    pttButton
                        .padding(.bottom, 30)
                }
            }
            .navigationTitle("Off-Grid PTT Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Constants.UI.Colors.backgroundDark, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
    
    // MARK: - Channel Header
    private var channelHeaderCard: some View {
        VStack(spacing: 10) {
            HStack {
                Label("ACTIVE CHANNEL", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Constants.UI.Colors.radioActive)
                Spacer()
                Text("\(viewModel.session.connectedPeersCount) PEERS LISTENING")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Constants.UI.Colors.textSecondary)
            }
            
            Picker("Channel", selection: $viewModel.selectedChannel) {
                ForEach(viewModel.availableChannels, id: \.self) { ch in
                    Text(ch).tag(ch)
                }
            }
            .pickerStyle(.segmented)
        }
        .glassCardStyle()
    }
    
    // MARK: - Speaker & Waveform Status
    private var speakerStatusView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(viewModel.isPTTPressed ? Constants.UI.Colors.radioActive.opacity(0.2) : Color.white.opacity(0.05))
                    .frame(width: 140, height: 140)
                
                if viewModel.isPTTPressed {
                    Circle()
                        .stroke(Constants.UI.Colors.radioActive, lineWidth: 3)
                        .frame(width: 160, height: 160)
                        .scaleEffect(waveAnimation ? 1.15 : 0.95)
                        .opacity(waveAnimation ? 0.2 : 0.9)
                        .onAppear {
                            withAnimation(Constants.UI.Animation.pttGlow) {
                                waveAnimation = true
                            }
                        }
                }
                
                Image(systemName: viewModel.isPTTPressed ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 50))
                    .foregroundColor(viewModel.isPTTPressed ? Constants.UI.Colors.radioActive : Constants.UI.Colors.textMuted)
            }
            
            VStack(spacing: 4) {
                Text(viewModel.isPTTPressed ? "TRANSMITTING LIVE VOICE" : (viewModel.session.isReceivingAudio ? "RECEIVING AUDIO..." : "READY TO TRANSMIT"))
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundColor(viewModel.isPTTPressed ? Constants.UI.Colors.radioActive : Constants.UI.Colors.textSecondary)
                
                if let activeSpeaker = viewModel.session.activeSpeakerName {
                    Text("Speaker: \(activeSpeaker)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Constants.UI.Colors.textPrimary)
                } else {
                    Text("Hold PTT button below to speak")
                        .font(.system(size: 12))
                        .foregroundColor(Constants.UI.Colors.textMuted)
                }
            }
            
            // Sound Wave Indicator Bars
            HStack(spacing: 4) {
                ForEach(0..<12) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(viewModel.isPTTPressed ? Constants.UI.Colors.radioActive : Color.gray.opacity(0.3))
                        .frame(width: 6, height: viewModel.isPTTPressed ? CGFloat.random(in: 12...44) : 8)
                }
            }
            .frame(height: 50)
        }
    }
    
    // MARK: - PTT Holding Button
    private var pttButton: some View {
        Button(action: {}) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: viewModel.isPTTPressed ? [Constants.UI.Colors.radioActive, Color.blue] : [Color(white: 0.25), Color(white: 0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 140, height: 140)
                    .shadow(color: viewModel.isPTTPressed ? Constants.UI.Colors.radioActive.opacity(0.6) : Color.black.opacity(0.4), radius: 15, x: 0, y: 8)
                
                VStack(spacing: 4) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 28))
                    Text("HOLD PTT")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                }
                .foregroundColor(.white)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !viewModel.isPTTPressed {
                        viewModel.startTransmittingVoice()
                    }
                }
                .onEnded { _ in
                    viewModel.stopTransmittingVoice()
                }
        )
    }
}
