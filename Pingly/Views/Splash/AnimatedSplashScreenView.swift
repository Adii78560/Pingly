//
//  AnimatedSplashScreenView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Minimal, Apple-Grade CoreAnimation & SwiftUI Splash Screen
struct AnimatedSplashScreenView: View {
    @Binding var isFinished: Bool
    
    // Core Animation States
    @State private var emblemScale: CGFloat = 0.85
    @State private var emblemOpacity: Double = 0.0
    @State private var textOpacity: Double = 0.0
    @State private var pulseRingScale: CGFloat = 0.95
    @State private var pulseRingOpacity: Double = 0.0
    
    var body: some View {
        ZStack {
            // Sleek Apple Dark Background
            Color(red: 0.06, green: 0.07, blue: 0.10)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                ZStack {
                    // Minimal Single Pulse Ring
                    Circle()
                        .stroke(AppTheme.ringStrokeGradient.opacity(pulseRingOpacity), lineWidth: 2.0)
                        .scaleEffect(pulseRingScale)
                        .frame(width: 96, height: 96)
                    
                    // Central Minimal App Emblem
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(AppTheme.primaryGradient)
                        .frame(width: 88, height: 88)
                        .shadow(color: AppTheme.hotMagenta.opacity(0.45), radius: 22, x: 0, y: 10)
                        .overlay(
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 36, weight: .bold))
                                .foregroundColor(.white)
                        )
                }
                .scaleEffect(emblemScale)
                .opacity(emblemOpacity)
                
                // Minimalist Branding Title
                VStack(spacing: 6) {
                    Text("Relayn")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text("Off-Grid Mesh Communication")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                .opacity(textOpacity)
            }
        }
        .onAppear {
            runMinimalAnimationSequence()
        }
    }
    
    private func runMinimalAnimationSequence() {
        // 1. Spring scale-in emblem & trigger tactical heartbeat haptic pulse
        HapticsManager.shared.heartbeatPulse()
        withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
            emblemScale = 1.0
            emblemOpacity = 1.0
        }

        
        // 2. Smooth text fade-in
        withAnimation(.easeOut(duration: 0.5).delay(0.2)) {
            textOpacity = 1.0
        }
        
        // 3. Single subtle mesh pulse ring expansion
        withAnimation(.easeOut(duration: 1.1).delay(0.3)) {
            pulseRingScale = 1.55
            pulseRingOpacity = 0.0
        }
        pulseRingOpacity = 0.6
        
        // 4. Smooth dissolve fade-out transition to Main App
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeInOut(duration: 0.4)) {
                isFinished = true
            }
        }
    }
}
