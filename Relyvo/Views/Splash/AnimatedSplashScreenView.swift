//
//  AnimatedSplashScreenView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import AudioToolbox

/// Minimal, Apple-Grade CoreAnimation & SwiftUI Splash Screen
struct AnimatedSplashScreenView: View {
    @Binding var isFinished: Bool
    
    // Core Animation States
    @State private var emblemScale: CGFloat = 0.85
    @State private var emblemOpacity: Double = 0.0
    @State private var textOpacity: Double = 0.0
    
    // Radar Ring States
    @State private var pulseRing1Scale: CGFloat = 0.8
    @State private var pulseRing1Opacity: Double = 0.6
    @State private var pulseRing2Scale: CGFloat = 0.8
    @State private var pulseRing2Opacity: Double = 0.6
    
    // Bottom Badge Dot State
    @State private var pulseDot: Bool = false
    
    var body: some View {
        ZStack {
            // 1. Canvas & Background (Deep matte OLED black)
            Color(red: 0.05, green: 0.06, blue: 0.08)
                .ignoresSafeArea()
            
            // Ultra-subtle, slow-pulsing radial glow centered behind the logo
            RadialGradient(
                colors: [Color(red: 0.85, green: 0.25, blue: 0.55).opacity(0.18), Color.clear],
                center: .center,
                startRadius: 10,
                endRadius: 180
            )
            .ignoresSafeArea()
            
            VStack {
                Spacer()
                
                ZStack {
                    // 2. Expanding Radar Mesh Rings (Motion & Atmosphere)
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.pink.opacity(0.5), .purple.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                        .scaleEffect(pulseRing1Scale)
                        .opacity(pulseRing1Opacity)
                        .frame(width: 104, height: 104)
                        
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.pink.opacity(0.5), .purple.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                        .scaleEffect(pulseRing2Scale)
                        .opacity(pulseRing2Opacity)
                        .frame(width: 104, height: 104)
                    
                    // 3. Hero Brand Squircle (Matching AppLogo.png)
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.32, blue: 0.44), Color(red: 0.58, green: 0.18, blue: 0.88)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 104, height: 104)
                        .shadow(color: Color(red: 0.85, green: 0.25, blue: 0.55).opacity(0.4), radius: 24, x: 0, y: 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        .overlay(
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 40, weight: .bold))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
                        )
                }
                .scaleEffect(emblemScale)
                .opacity(emblemOpacity)
                
                // 4. Brand Typography & Subtitle
                VStack(spacing: 6) {
                    Text("Relyvo")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text("OFF-GRID MESH COMMUNICATION")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .kerning(1.8)
                        .foregroundColor(Color.white.opacity(0.65))
                }
                .padding(.top, 24)
                .opacity(textOpacity)
                
                Spacer()
                
                // 5. Bottom Tactical Readiness Badge
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulseDot ? 1.2 : 0.8)
                    
                    Text("MESH ENGINE READY")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 32)
                .opacity(textOpacity)
            }
        }
        .onAppear {
            runMinimalAnimationSequence()
        }
    }
    
    private func runMinimalAnimationSequence() {
        // Entrance Animation
        AudioServicesPlaySystemSound(1327) // Play a soothing 'Bloom' system chime
        
        // Logo squircle springs into view
        withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) {
            emblemScale = 1.0
            emblemOpacity = 1.0
        }
        
        // Trigger a crisp light haptic feedback the moment the logo settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            #if !targetEnvironment(simulator)
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
            #endif
        }
        
        // Smooth text fade-in
        withAnimation(.easeOut(duration: 0.5).delay(0.2)) {
            textOpacity = 1.0
        }
        
        // Radar mesh rings animation
        withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
            pulseRing1Scale = 2.2
            pulseRing1Opacity = 0.0
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
                pulseRing2Scale = 2.2
                pulseRing2Opacity = 0.0
            }
        }
        
        // Dot pulse animation
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulseDot = true
        }
        
        // 6. Seamless Handoff to Main App
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeInOut(duration: 0.35)) {
                isFinished = true
            }
        }
    }
}
