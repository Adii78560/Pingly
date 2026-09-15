//
//  OfflineNavigationView.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import SwiftUI
import CoreLocation

/// Flagship Dual-Mode Offline Emergency Navigation & Tactical Guidance HUD
struct OfflineNavigationView: View {
    @StateObject private var viewModel: NavigationViewModel
    @Environment(\.dismiss) private var dismiss
    
    init(target: NavigationTarget) {
        _viewModel = StateObject(wrappedValue: NavigationViewModel(initialTarget: target))
    }
    
    var body: some View {
        ZStack {
            // Background Theme
            Color(red: 0.04, green: 0.06, blue: 0.08)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // MARK: - Navigation Header HUD
                navigationHeader
                
                // MARK: - Primary Display Modes
                if viewModel.displayMode == .compass {
                    if viewModel.navigationMode == .roadRoute {
                        roadNavigationModeView
                    } else {
                        compassRadarModeView
                    }
                } else {
                    TacticalMapView()
                        .environmentObject(viewModel)
                }
                
                // MARK: - Bottom Tactical Action Bar
                bottomActionBar
            }
        }
        .sheet(isPresented: $viewModel.showTechnicalDetails) {
            technicalCoordinatesSheet
                .presentationDetents([.fraction(0.4)])
        }
    }
    
    // MARK: - Subviews
    
    private var navigationHeader: some View {
        VStack(spacing: 8) {
            HStack {
                // Target Identity & Type Pill
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.target?.targetType.iconName ?? "location.fill")
                            .foregroundColor(viewModel.target?.targetType == .sos ? .red : .orange)
                        Text(viewModel.target?.displayName ?? "Unknown Target")
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                    }
                    
                    if viewModel.isRoutingCalculationActive {
                        Text("Calculating route...")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.orange)
                    } else if let target = viewModel.target {
                        HStack(spacing: 6) {
                            // Staleness Status Pill
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(stalenessColor(target.staleness))
                                    .frame(width: 6, height: 6)
                                Text(target.staleness.badgeTitle)
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .foregroundColor(stalenessColor(target.staleness))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(stalenessColor(target.staleness).opacity(0.15)))
                            
                            Text(target.humanAgeDescription)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.gray)
                        }
                    }
                }
                
                Spacer()
                
                // Close / Stop Button
                Button(action: {
                    viewModel.stopNavigation()
                    dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.gray.opacity(0.8))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            // Mode Switcher Tabs
            HStack(spacing: 0) {
                ForEach(NavigationDisplayMode.allCases, id: \.self) { mode in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.displayMode = mode
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: mode.iconName)
                                .font(.system(size: 12, weight: .bold))
                            Text(mode.rawValue)
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                        }
                        .foregroundColor(viewModel.displayMode == mode ? .black : .gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            viewModel.displayMode == mode ?
                            RoundedRectangle(cornerRadius: 8).fill(Color.orange) :
                            RoundedRectangle(cornerRadius: 8).fill(Color.clear)
                        )
                    }
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .background(Color(red: 0.07, green: 0.09, blue: 0.12))
    }
    
    // MARK: - Mode A: Compass Vector Radar View
    
    private var compassRadarModeView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Human Navigation Guidance Instruction Banner
            if let vector = viewModel.vector {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: vector.instruction.iconName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(vector.isArrived ? .green : (vector.isAligned ? .orange : .white))
                        
                        Text(vector.instruction.text.uppercased())
                            .font(.system(size: 17, weight: .black, design: .rounded))
                            .foregroundColor(vector.isArrived ? .green : (vector.isAligned ? .orange : .white))
                    }
                    
                    HStack(spacing: 12) {
                        Text("\(vector.cardinal.arrowSymbol) \(String(format: "%.0f°", vector.initialBearingDegrees)) \(vector.cardinal.abbreviation)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                        
                        if vector.distanceTrend != .stationary {
                            HStack(spacing: 4) {
                                Image(systemName: vector.distanceTrend == .closing ? "arrow.down.forward" : "arrow.up.forward")
                                Text(vector.distanceTrend.rawValue)
                            }
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(vector.distanceTrend == .closing ? .green : .yellow)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(vector.isAligned ? Color.orange.opacity(0.12) : Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(vector.isAligned ? Color.orange.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 20)
            }
            
            // Rotating Compass Radar Dial
            ZStack {
                // Outer Static Bezel & Degree Scale
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 2)
                    .frame(width: 270, height: 270)
                
                // Range Concentric Rings
                Circle()
                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
                    .frame(width: 180, height: 180)
                Circle()
                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
                    .frame(width: 90, height: 90)
                
                // Rotating Compass Dial (Smooth Circular Angle without jumps)
                ZStack {
                    // Cardinal Labels (N, E, S, W)
                    VStack {
                        Text("N")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .foregroundColor(.red)
                        Spacer()
                        Text("S")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .frame(height: 250)
                    
                    HStack {
                        Text("W")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                        Spacer()
                        Text("E")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .frame(width: 250)
                }
                .rotationEffect(.degrees(-viewModel.continuousHeading))
                
                // Target Direction Pointer Vector (Relative Bearing)
                if let vector = viewModel.vector {
                    VStack {
                        // High-visibility pointer head
                        ZStack {
                            Circle()
                                .fill(vector.isAligned ? Color.orange : (viewModel.target?.targetType == .sos ? Color.red : Color.cyan))
                                .frame(width: 32, height: 32)
                                .shadow(color: Color.orange.opacity(0.8), radius: vector.isAligned ? 10 : 0)
                            
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .black))
                                .foregroundColor(.black)
                        }
                        
                        // Vector Ray Line
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.orange.opacity(0.8), Color.orange.opacity(0.0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 3, height: 80)
                        
                        Spacer()
                    }
                    .frame(height: 260)
                    .rotationEffect(.degrees(vector.relativeBearingDegrees))
                }
                
                // User Core Center Node
                ZStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                        .shadow(color: .blue.opacity(0.8), radius: 8)
                    
                    Image(systemName: "person.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 280, height: 280)
            
            // Large Distance Metric
            if let vector = viewModel.vector {
                VStack(spacing: 2) {
                    Text(vector.formattedDistance)
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text("DISTANCE TO TARGET")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
        }
    }
    
    // MARK: - Mode B: Road Route HUD
    
    private var roadNavigationModeView: some View {
        VStack {
            Spacer()
            
            if viewModel.isRerouting {
                Text("Recalculating Route...")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundColor(.orange)
                    .padding()
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(12)
            } else if let progress = viewModel.routeProgress {
                if progress.isArrived {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.green)
                        
                        Text("ARRIVED")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundColor(.green)
                    }
                    .padding()
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(16)
                } else if let maneuver = progress.nextManeuver {
                    VStack(spacing: 16) {
                        // Maneuver Icon and Distance
                        HStack(alignment: .center, spacing: 20) {
                            Image(systemName: getManeuverIcon(maneuver.type))
                                .font(.system(size: 64, weight: .bold))
                                .foregroundColor(.white)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(formatDistance(maneuver.distanceFromCurrentPosition))
                                    .font(.system(size: 48, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                                
                                Text(maneuver.instructionText.uppercased())
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundColor(.orange)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        
                        Divider().background(Color.white.opacity(0.2))
                        
                        // Remaining Route Stats
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("REMAINING")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                Text(formatDistance(progress.remainingDistanceMeters))
                                    .font(.system(size: 20, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("ETA")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                Text(formatTime(seconds: progress.estimatedRemainingTimeSeconds))
                                    .font(.system(size: 20, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .padding(24)
                    .background(Color.black.opacity(0.4))
                    .cornerRadius(20)
                    .padding(.horizontal, 16)
                }
            } else {
                Text("Waiting for GPS location...")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.gray)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Bottom Action Bar
    
    private var bottomActionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Return to Start Trigger (Only in directTarget mode typically, but available)
                Button(action: {
                    viewModel.returnToStart()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: 14))
                        Text("RETURN")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                }
                
                // Toggle Voice Guidance
                Button(action: {
                    viewModel.toggleVoice()
                }) {
                    Image(systemName: viewModel.voiceGuidanceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(viewModel.voiceGuidanceEnabled ? .orange : .gray)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                }
                
                // Toggle Directional Haptics
                Button(action: {
                    viewModel.toggleHaptics()
                }) {
                    Image(systemName: viewModel.isHapticsEnabled ? "waveform.badge.magnifyingglass" : "waveform.slash")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(viewModel.isHapticsEnabled ? .orange : .gray)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                }
                
                // Technical Coordinates Details Button
                Button(action: {
                    viewModel.showTechnicalDetails = true
                }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.gray)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(Color(red: 0.07, green: 0.09, blue: 0.12))
    }
    
    // MARK: - Technical Coordinates Sheet (Collapsible / Advanced View)
    
    private var technicalCoordinatesSheet: some View {
        NavigationStack {
            List {
                Section("Target Coordinates (WGS84)") {
                    if let target = viewModel.target {
                        LabeledContent("Latitude", value: String(format: "%.6f°", target.coordinate.latitude))
                        LabeledContent("Longitude", value: String(format: "%.6f°", target.coordinate.longitude))
                        if let alt = target.altitude {
                            LabeledContent("Altitude", value: String(format: "%.1f m", alt))
                        }
                        LabeledContent("GPS Accuracy", value: String(format: "±%.1f m", target.accuracy))
                        LabeledContent("Timestamp", value: target.timestamp.formatted(date: .omitted, time: .standard))
                        LabeledContent("Sequence #", value: "\(target.sequenceNumber)")
                    }
                }
                
                if viewModel.navigationMode == .directTarget {
                    Section("Calculation Metrics") {
                        if let vector = viewModel.vector {
                            LabeledContent("Exact Distance", value: String(format: "%.2f meters", vector.distanceMeters))
                            LabeledContent("Initial True Bearing", value: String(format: "%.1f°", vector.initialBearingDegrees))
                            LabeledContent("Relative Bearing", value: String(format: "%.1f°", vector.relativeBearingDegrees))
                            LabeledContent("User True Heading", value: String(format: "%.1f°", vector.userHeadingDegrees))
                            LabeledContent("Data Freshness", value: viewModel.target?.staleness.badgeTitle ?? "UNKNOWN")
                        }
                    }
                } else if viewModel.navigationMode == .roadRoute {
                    Section("Routing Metrics") {
                        if let progress = viewModel.routeProgress {
                            LabeledContent("Remaining Dist", value: String(format: "%.2f m", progress.remainingDistanceMeters))
                            LabeledContent("Traveled Dist", value: String(format: "%.2f m", progress.distanceAlongRouteMeters))
                            LabeledContent("Off Route Dist", value: String(format: "%.2f m", progress.distanceToRouteMeters))
                            LabeledContent("State", value: viewModel.routeState.rawValue)
                        }
                    }
                }
            }
            .navigationTitle("Technical Metrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { viewModel.showTechnicalDetails = false }
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func stalenessColor(_ staleness: TargetStaleness) -> Color {
        switch staleness {
        case .live: return .green
        case .recent: return .yellow
        case .stale: return .orange
        case .expired: return .red
        }
    }
    
    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return String(format: "%.0f m", meters)
        } else {
            return String(format: "%.1f km", meters / 1000.0)
        }
    }
    
    private func formatTime(seconds: Double) -> String {
        if seconds < 60 {
            return "< 1 min"
        }
        let mins = Int(seconds) / 60
        if mins < 60 {
            return "\(mins) min"
        }
        let hrs = mins / 60
        let remMins = mins % 60
        return "\(hrs)h \(remMins)m"
    }
    
    private func getManeuverIcon(_ type: ManeuverType) -> String {
        switch type {
        case .start, .`continue`: return "arrow.up"
        case .slightRight: return "arrow.up.right"
        case .right: return "arrow.turn.up.right"
        case .sharpRight: return "arrow.right.circle.fill"
        case .slightLeft: return "arrow.up.left"
        case .left: return "arrow.turn.up.left"
        case .sharpLeft: return "arrow.left.circle.fill"
        case .uTurn: return "arrow.uturn.down"
        case .arrive: return "checkmark.circle"
        }
    }
}
