//
//  VoiceMessageBubbleView.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 26/08/26.
//

import SwiftUI

/// Elegant voice note message bubble replacing raw text transcripts in channel history.
struct VoiceMessageBubbleView: View {
    let message: VoiceMessage
    @ObservedObject private var player = VoiceMessagePlayerManager.shared
    
    private var isCurrentPlaying: Bool {
        player.playingMessageID == message.id && player.isPlaying
    }
    
    private var progress: Double {
        if player.playingMessageID == message.id {
            return player.playbackProgress
        }
        return 0.0
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isSender {
                Spacer(minLength: 40)
            } else {
                // Remote Sender Avatar
                ZStack {
                    Circle()
                        .fill(AppTheme.primaryGradient)
                        .frame(width: 34, height: 34)
                        .shadow(color: AppTheme.hotMagenta.opacity(0.3), radius: 4, x: 0, y: 2)
                    
                    Text(message.senderAlias.prefix(2).uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            
            VStack(alignment: message.isSender ? .trailing : .leading, spacing: 4) {
                // Header: Sender Name & Relative Time
                HStack(spacing: 6) {
                    Text(message.isSender ? "You" : message.senderAlias)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text("• \(message.timestamp.relativeTimeAgo)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    if message.isSender {
                        Image(systemName: message.isDelivered ? "checkmark.circle.fill" : "arrow.up.circle")
                            .font(.system(size: 10))
                            .foregroundColor(message.isDelivered ? .green : .orange)
                    }
                }
                
                let isAvailable = player.isAudioFileAvailable(for: message)
                
                // Voice Note Card
                HStack(spacing: 12) {
                    // Play/Pause Circular Button
                    Button {
                        if isAvailable {
                            player.togglePlay(for: message)
                            HapticManager.selectionFeedback()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isAvailable ? (message.isSender ? Color.white : AppTheme.tintColor) : Color.gray.opacity(0.3))
                                .frame(width: 38, height: 38)
                                .shadow(color: Color.black.opacity(isAvailable ? 0.15 : 0.0), radius: 4, x: 0, y: 2)
                            
                            Image(systemName: isAvailable ? (isCurrentPlaying ? "pause.fill" : "play.fill") : "waveform.slash")
                                .font(.system(size: isAvailable ? 15 : 13, weight: .bold))
                                .foregroundColor(isAvailable ? (message.isSender ? AppTheme.tintColor : .white) : .secondary)
                                .offset(x: isAvailable && !isCurrentPlaying ? 1 : 0)
                        }
                    }
                    .disabled(!isAvailable)
                    
                    // Waveform / Progress Track
                    VStack(alignment: .leading, spacing: 5) {
                        // Simulated Waveform Bars with Progress Mask
                        GeometryReader { geo in
                            let barCount = 20
                            let spacing: CGFloat = 3.0
                            let totalSpacing = spacing * CGFloat(barCount - 1)
                            let barWidth = max(2.0, (geo.size.width - totalSpacing) / CGFloat(barCount))
                            
                            HStack(alignment: .center, spacing: spacing) {
                                ForEach(0..<barCount, id: \.self) { idx in
                                    let normalizedBarProgress = Double(idx) / Double(barCount)
                                    let isPlayedBar = normalizedBarProgress <= progress
                                    let barHeight = waveformHeight(for: idx, total: barCount)
                                    
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(
                                            isAvailable
                                                ? (isPlayedBar
                                                    ? (message.isSender ? Color.white : AppTheme.tintColor)
                                                    : (message.isSender ? Color.white.opacity(0.4) : Color.gray.opacity(0.35)))
                                                : Color.gray.opacity(0.2)
                                        )
                                        .frame(width: barWidth, height: isAvailable ? barHeight : 6)
                                }
                            }
                        }
                        .frame(height: 22)
                        
                        // Duration & Playback Time Label
                        HStack {
                            if !isAvailable {
                                Text("Audio Expired")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(message.isSender ? .white.opacity(0.7) : .secondary)
                            } else if player.playingMessageID == message.id {
                                Text(formatTime(player.currentTime))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(message.isSender ? .white.opacity(0.9) : .secondary)
                            }
                            
                            Spacer()
                            
                            Text(message.formattedDuration)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(message.isSender ? .white.opacity(0.85) : .secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Group {
                        if message.isSender {
                            AppTheme.primaryGradient
                        } else {
                            Color(UIColor.secondarySystemGroupedBackground)
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
            }
            
            if !message.isSender {
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
    
    private func waveformHeight(for index: Int, total: Int) -> CGFloat {
        let pattern: [CGFloat] = [8, 14, 20, 12, 18, 22, 16, 10, 14, 22, 18, 12, 20, 16, 14, 22, 18, 12, 10, 8]
        return pattern[index % pattern.count]
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
