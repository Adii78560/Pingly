//
//  RelativeLocationView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 14/08/26.
//

import SwiftUI
import CoreLocation

/// Dedicated original SwiftUI view for Two-Person Relative Positioning and Dynamic Compass Visualization
struct RelativeLocationView: View {
    let remotePeerID: String
    let remoteDisplayName: String
    
    @StateObject private var locationService = LocationService.shared
    @StateObject private var locationShareManager = LocationShareManager.shared
    @StateObject private var multipeerService = MultipeerService.shared
    
    @State private var continuousRelativeBearing: Double = 0.0
    @State private var previousRawRelBearing: Double = 0.0
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // Background Theme Gradient
            Color(UIColor.systemGroupedBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header Bar
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(remoteDisplayName.cleanBaseName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isPeerConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(sessionStateDescription)
                                .font(.caption.weight(.medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 16)
                
                Spacer()
                
                // Compass Radar Visualization Circle
                ZStack {
                    // Outer Pulsing Radar Rings
                    Circle()
                        .stroke(AppTheme.primaryGradient, lineWidth: 2)
                        .frame(width: 280, height: 280)
                        .opacity(0.3)
                    
                    Circle()
                        .stroke(AppTheme.primaryGradient, lineWidth: 1)
                        .frame(width: 210, height: 210)
                        .opacity(0.2)
                    
                    Circle()
                        .stroke(AppTheme.primaryGradient, lineWidth: 1)
                        .frame(width: 140, height: 140)
                        .opacity(0.15)
                    
                    // Rotating Cardinal Compass Ring (N, E, S, W)
                    ZStack {
                        Text("N")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(AppTheme.tintColor)
                            .offset(y: -125)
                        Text("E")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .offset(x: 125)
                        Text("S")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .offset(y: 125)
                        Text("W")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .offset(x: -125)
                    }
                    // Unwind rotation to keep map visually pointing north
                    .rotationEffect(.degrees(-locationService.smoothedHeading))
                    .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: locationService.smoothedHeading)
                    
                    // Central "YOU" User Node
                    VStack(spacing: 2) {
                        Image(systemName: "location.north.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(isLockedOn ? AnyShapeStyle(Color.green) : AnyShapeStyle(AppTheme.primaryGradient))
                            .rotationEffect(.degrees(continuousRelativeBearing))
                            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: continuousRelativeBearing)
                        Text("YOU")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    
                    // Orbiting Directional Target Beacon (Remote User)
                    if let _ = currentRelativeInfo {
                        ZStack {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(isLockedOn ? Color.green : AppTheme.tintColor)
                                    .frame(width: 16, height: 16)
                                    .shadow(color: isLockedOn ? Color.green : AppTheme.tintColor, radius: 8)
                                
                                Text(remoteDisplayName.cleanBaseName)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(UIColor.secondarySystemGroupedBackground))
                                    .cornerRadius(6)
                            }
                            .offset(y: -95)
                        }
                        .rotationEffect(.degrees(continuousRelativeBearing))
                        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: continuousRelativeBearing)
                    }
                }
                .frame(width: 300, height: 300)
                
                Spacer()
                
                // Distance & Accuracy Metrics Card
                VStack(spacing: 8) {
                    if let relInfo = currentRelativeInfo {
                        Text(relInfo.distanceFormatted)
                            .font(.system(size: 38, weight: .heavy, design: .rounded))
                            .foregroundStyle(AppTheme.primaryGradient)
                        
                        HStack(spacing: 12) {
                            Label("±\(Int(remoteAccuracy)) m", systemImage: "scope")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                            
                            Text("•")
                                .foregroundColor(.secondary)
                            
                            Label(remoteAgeText, systemImage: "clock")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(emptyStateTitle)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        Text(emptyStateSubtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal)
                
                // Bottom Action Bar Controls
                HStack(spacing: 12) {
                    if isSharingLocal {
                        Button(action: {
                            locationShareManager.stopSharingLocation(with: remotePeerID, displayName: remoteDisplayName)
                        }) {
                            Label("Stop Sharing", systemImage: "location.slash.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .cornerRadius(12)
                        }
                    } else {
                        Button(action: {
                            locationShareManager.startSharingLocation(with: remotePeerID, displayName: remoteDisplayName)
                        }) {
                            Label("Share My Location", systemImage: "location.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(AppTheme.primaryGradient)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }
                    
                    Button(action: {
                        locationShareManager.requestLocation(from: remotePeerID, displayName: remoteDisplayName)
                    }) {
                        Label("Request Update", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            LocationService.shared.startSharingLocation()
            locationShareManager.reloadActiveSessions()
            updateContinuousRelativeBearing()
        }
        .onChange(of: locationService.smoothedHeading) { _ in
            updateContinuousRelativeBearing()
        }
        .onChange(of: session?.lastRemoteTimestamp) { _ in
            updateContinuousRelativeBearing()
        }
    }
    
    private func updateContinuousRelativeBearing() {
        guard let relInfo = currentRelativeInfo else { return }
        let rawRel = relInfo.relativeBearing
        let delta = CircularAngleHelper.shortestAngularDifference(from: previousRawRelBearing, to: rawRel)
        previousRawRelBearing = rawRel
        
        let wasLockedOn = isLockedOn
        continuousRelativeBearing += delta
        
        if !wasLockedOn && isLockedOn {
            CompassHapticManager.shared.playHeadingDetent()
        }
        
        CompassHapticManager.shared.evaluateCompassState(relativeBearing: relInfo.relativeBearing, distanceMeters: relInfo.distanceMeters)
    }
    
    private var isLockedOn: Bool {
        let normalized = continuousRelativeBearing.truncatingRemainder(dividingBy: 360)
        let positiveNormalized = normalized >= 0 ? normalized : normalized + 360
        return positiveNormalized <= 5.0 || positiveNormalized >= 355.0
    }
    
    // MARK: - Computed State Helpers
    
    private var session: LocationSessionState? {
        return locationShareManager.getSession(for: remotePeerID)
    }
    
    private var isPeerConnected: Bool {
        return multipeerService.connectedPeers.contains(where: { $0.id == remotePeerID })
    }
    
    private var isSharingLocal: Bool {
        return session?.isSharingLocal ?? false
    }
    
    private var isSharingRemote: Bool {
        return session?.isSharingRemote ?? false
    }
    
    private var remoteAccuracy: Double {
        return session?.lastRemoteAccuracy ?? 10.0
    }
    
    private var remoteAgeText: String {
        guard let timestamp = session?.lastRemoteTimestamp else { return "No timestamp" }
        let seconds = Int(Date().timeIntervalSince(timestamp))
        if seconds < 5 {
            return "Updated just now"
        } else if seconds < 60 {
            return "Updated \(seconds)s ago"
        } else {
            return "Updated \(seconds / 60)m ago"
        }
    }
    
    private var currentRelativeInfo: (distanceMeters: Double, initialBearing: Double, relativeBearing: Double, distanceFormatted: String, compassDirection: String)? {
        guard let lat = session?.lastRemoteLatitude,
              let lon = session?.lastRemoteLongitude else { return nil }
        return locationService.relativeBearing(toLat: lat, lon: lon)
    }
    
    private var sessionStateDescription: String {
        guard isPeerConnected else { return "Mesh Peer Disconnected" }
        if isSharingLocal && isSharingRemote {
            return "Two-Way Location Active"
        } else if isSharingRemote {
            return "Receiving \(remoteDisplayName.cleanBaseName)'s Location"
        } else if isSharingLocal {
            return "Sharing Location with \(remoteDisplayName.cleanBaseName)"
        } else {
            return "Location Sharing Inactive"
        }
    }
    
    private var emptyStateTitle: String {
        if session?.stateRaw == "REQUEST_PENDING" {
            return "Location Request Sent"
        } else if !isPeerConnected {
            return "Peer Offline"
        } else {
            return "Waiting for Location Data"
        }
    }
    
    private var emptyStateSubtitle: String {
        if session?.stateRaw == "REQUEST_PENDING" {
            return "Waiting for \(remoteDisplayName.cleanBaseName) to accept location request."
        } else if !isPeerConnected {
            return "\(remoteDisplayName.cleanBaseName) is not reachable in current mesh range."
        } else {
            return "Tap 'Request Update' or 'Share My Location' to establish positioning."
        }
    }
}
