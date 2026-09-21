//
//  OfflineNavigationView.swift
//  Relyvo
//

import SwiftUI
import CoreLocation

/// Flagship Apple Find My Precision Finding UI
struct OfflineNavigationView: View {
    @StateObject private var viewModel: NavigationViewModel
    @Environment(\.dismiss) private var dismiss
    
    // Haptic Debounce
    @State private var lastHapticTime: Date = Date.distantPast
    
    // Unwrapped Local Rotation State
    @State private var needleRotation: Double = 0
    @State private var isPulsing: Bool = false
    
    let targetPeerName: String
    
    init(target: NavigationTarget) {
        _viewModel = StateObject(wrappedValue: NavigationViewModel(initialTarget: target))
        self.targetPeerName = target.displayName
    }
    
    var body: some View {
        let isAligned = determineAlignment()
        let backgroundColor = isAligned ? Color(red: 0.12, green: 0.78, blue: 0.35) : Color(red: 0.85, green: 0.18, blue: 0.18)
        
        ZStack {
            // Edge-to-Edge Background
            backgroundColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.28), value: isAligned)
            
            VStack {
                // Top-Left Target Identity Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FINDING")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.8))
                        
                        Text(targetPeerName)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                
                Spacer()
                
                // Center Navigation Stage
                if let vector = viewModel.vector {
                    let targetBearing = vector.initialBearingDegrees
                    let normalizedDelta = ((targetBearing - (viewModel.smoothedHeading.truncatingRemainder(dividingBy: 360)) + 540).truncatingRemainder(dividingBy: 360)) - 180
                    
                    let angleRadians = (needleRotation - 90) * (.pi / 180.0)
                    let orbitRadius: CGFloat = 150
                    let dotX = cos(angleRadians) * orbitRadius
                    let dotY = sin(angleRadians) * orbitRadius
                    
                    ZStack {
                        if vector.distanceMeters < 3.0 {
                            // Arrived State
                            Circle()
                                .fill(Color.white)
                                .frame(width: 80, height: 80)
                                .scaleEffect(isPulsing ? 1.15 : 1.0)
                                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                                .onAppear { isPulsing = true }
                                .onDisappear { isPulsing = false }
                            
                            Text("Here")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundColor(Color(red: 0.12, green: 0.78, blue: 0.35))
                        } else {
                            // Directional Arrow (Centered)
                            FindMyArrowShape()
                                .fill(Color.white)
                                .frame(width: 110, height: 140)
                                .rotationEffect(.degrees(needleRotation))
                                .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.88, blendDuration: 0), value: needleRotation)
                            
                            // Target Orb (Orbiting)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 20, height: 20)
                                .offset(x: dotX, y: dotY)
                                .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.88, blendDuration: 0), value: needleRotation)
                        }
                    }
                    .frame(width: 300, height: 300)
                    .onChange(of: normalizedDelta) { _, newValue in
                        if abs(newValue) <= 8.0 {
                            let now = Date()
                            if now.timeIntervalSince(lastHapticTime) > 1.5 {
                                CompassHapticManager.shared.playHeadingDetent()
                                lastHapticTime = now
                            }
                        }
                    }
                } else {
                    Text("Searching for signal...")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.6))
                }
                
                Spacer()
                
                // Bottom-Left Distance & Direction Readout
                if let vector = viewModel.vector {
                    let targetBearing = vector.initialBearingDegrees
                    let normalizedDelta = ((targetBearing - (viewModel.smoothedHeading.truncatingRemainder(dividingBy: 360)) + 540).truncatingRemainder(dividingBy: 360)) - 180
                    let distMeters = vector.distanceMeters
                    
                    let formattedTuple = formatLargeDistance(distMeters)
                    let directionLabel = getDirectionLabel(delta: normalizedDelta)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: -4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(formattedTuple.value)
                                    .font(.system(size: 64, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                
                                Text(formattedTuple.unit)
                                    .font(.system(size: 40, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            
                            Text(directionLabel)
                                .font(.system(size: 38, weight: .medium, design: .rounded))
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
                
                // Bottom Floating Action Buttons
                HStack {
                    Button(action: {
                        viewModel.stopNavigation()
                        dismiss()
                    }) {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 56, height: 56)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.title3.bold())
                                    .foregroundColor(.white)
                            )
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        viewModel.stopNavigation()
                        dismiss()
                        // Post notification for chat quick-link if possible
                        if let peerID = viewModel.target?.id, let name = viewModel.target?.displayName {
                            NotificationCenter.default.post(name: NSNotification.Name("NavigateToDirectMessage"), object: nil, userInfo: ["peerID": peerID, "displayName": name])
                        }
                    }) {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 56, height: 56)
                            .overlay(
                                Image(systemName: "bubble.fill")
                                    .font(.title3.bold())
                                    .foregroundColor(.white)
                            )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .onChange(of: viewModel.smoothedHeading) { _, newHeading in
            if let targetBearing = viewModel.vector?.initialBearingDegrees {
                updateNeedleAngle(targetBearing: targetBearing, currentHeading: newHeading)
            }
        }
        .onChange(of: viewModel.vector?.initialBearingDegrees) { _, newBearing in
            if let targetBearing = newBearing {
                updateNeedleAngle(targetBearing: targetBearing, currentHeading: viewModel.smoothedHeading)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func updateNeedleAngle(targetBearing: Double, currentHeading: Double) {
        // Target relative angle between [-180, 180]
        var targetRelative = (targetBearing - currentHeading).truncatingRemainder(dividingBy: 360)
        if targetRelative > 180 { targetRelative -= 360 }
        if targetRelative < -180 { targetRelative += 360 }

        // Shortest angular step from current needle position
        var delta = targetRelative - (needleRotation.truncatingRemainder(dividingBy: 360))
        delta = (delta + 540).truncatingRemainder(dividingBy: 360) - 180

        // Accumulate only the direct step
        needleRotation += delta
    }
    
    private func determineAlignment() -> Bool {
        guard let vector = viewModel.vector else { return false }
        let targetBearing = vector.initialBearingDegrees
        let normalizedDelta = ((targetBearing - (viewModel.smoothedHeading.truncatingRemainder(dividingBy: 360)) + 540).truncatingRemainder(dividingBy: 360)) - 180
        return abs(normalizedDelta) <= 15.0
    }
    
    private func getDirectionLabel(delta: Double) -> String {
        if abs(delta) <= 15 {
            return "ahead"
        } else if delta > 15 && delta <= 90 {
            return "to your right"
        } else if delta >= -90 && delta < -15 {
            return "to your left"
        } else {
            return "behind you"
        }
    }
    
    private func formatLargeDistance(_ meters: Double) -> (value: String, unit: String) {
        if meters < 1000 {
            return (String(format: "%.0f", meters), "m")
        } else {
            return (String(format: "%.1f", meters / 1000.0), "km")
        }
    }
}

struct FindMyArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.15))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
