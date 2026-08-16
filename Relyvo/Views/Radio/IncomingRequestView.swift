//
//  IncomingRequestView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

//
//  IncomingRequestView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Native FaceTime Audio / Walkie-Talkie Call Overlay Sheet
struct IncomingRequestView: View {
    let peerName: String
    let rssi: Int
    let channelName: String
    let onAccept: () -> Void
    let onDecline: () -> Void
    
    @State private var timeRemaining: Double = 15.0
    @State private var timer: Timer? = nil
    @State private var waveAnimation: Bool = false
    
    var body: some View {
        ZStack {
            // Full-screen frosted backdrop
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)
            
            VStack(spacing: 24) {
                Spacer()
                
                // Avatar with subtle pulse
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.4), lineWidth: 2)
                        .frame(width: 100, height: 100)
                        .scaleEffect(waveAnimation ? 1.3 : 1.0)
                        .opacity(waveAnimation ? 0.0 : 0.6)
                        .animation(Animation.easeInOut(duration: 1.8).repeatForever(autoreverses: false), value: waveAnimation)
                    
                    Circle()
                        .fill(AppTheme.primaryGradient)
                        .frame(width: 90, height: 90)
                        .shadow(color: AppTheme.hotMagenta.opacity(0.4), radius: 10, x: 0, y: 4)
                    
                    Text(peerName.initials)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                }
                
                // Contact & Call Metadata Panel
                VStack(spacing: 6) {
                    Text(peerName)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("P2P Walkie-Talkie Call")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.gray)
                    
                    HStack(spacing: 6) {
                        Text("Channel: \(channelName)")
                        Text("•")
                        Text("\(rssi) dBm")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                }
                
                // Countdown Progress Bar
                ProgressView(value: timeRemaining, total: 15.0)
                    .tint(.blue)
                    .padding(.horizontal, 40)
                
                Spacer()
                
                // FaceTime Call Buttons (Decline & Accept)
                HStack(spacing: 50) {
                    // Decline Button (Red 72px)
                    Button(action: {
                        HapticManager.heavyImpact()
                        onDecline()
                    }) {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 72, height: 72)
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white)
                            }
                            Text("Decline")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                    
                    // Accept Button (Green 72px)
                    Button(action: {
                        HapticManager.successFeedback()
                        onAccept()
                    }) {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 72, height: 72)
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white)
                            }
                            Text("Accept")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            startTimer()
            waveAnimation = true
            HapticManager.heavyImpact()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if timeRemaining > 0 {
                timeRemaining -= 0.1
            } else {
                timer?.invalidate()
                onDecline()
            }
        }
    }
}

