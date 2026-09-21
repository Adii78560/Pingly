//
//  LocationMessageCardView.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/08/26.
//

import SwiftUI
import CoreLocation

/// Human-centered location card displaying distance, direction, staleness, and one-tap offline navigation CTA
struct LocationMessageCardView: View {
    let senderName: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let timestamp: Date
    let isCurrentUser: Bool
    var isSOS: Bool = false
    
    @State private var isNavigatingPresented: Bool = false
    @State private var showRawCoordinates: Bool = false
    @ObservedObject private var locationService = LocationService.shared
    
    private var target: NavigationTarget {
        NavigationTarget(
            id: senderName,
            displayName: senderName,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            accuracy: accuracy ?? 5.0,
            timestamp: timestamp,
            targetType: isSOS ? .sos : .peer
        )
    }
    
    private var navigationMetrics: (distance: String, cardinal: CardinalDirection, bearing: Double)? {
        guard let userCoord = locationService.currentCoordinate else { return nil }
        let distMeters = OfflineNavigationService.shared.calculateDistance(from: userCoord, to: target.coordinate)
        let bearingDeg = OfflineNavigationService.shared.calculateBearing(from: userCoord, to: target.coordinate)
        let cardinal = CardinalDirection(bearing: bearingDeg)
        let formattedDist = OfflineNavigationService.shared.formatDistance(meters: distMeters)
        return (formattedDist, cardinal, bearingDeg)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Name & Freshness
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isSOS ? Color.red : (isCurrentUser ? Color.white.opacity(0.2) : AppTheme.glassTint))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: isSOS ? "sos.circle.fill" : (isCurrentUser ? "location.fill" : "person.fill"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isCurrentUser ? .white : (isSOS ? .white : AppTheme.tintColor))
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(isCurrentUser ? "Your Shared Location" : (isSOS ? "🚨 SOS: \(senderName)" : senderName))
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundColor(isCurrentUser ? .white : .primary)
                    
                    Text(target.humanAgeDescription)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isCurrentUser ? .white.opacity(0.8) : .secondary)
                }
                
                Spacer()
                
                // Staleness Tag
                Text(target.staleness.badgeTitle)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(stalenessColor(target.staleness))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(stalenessColor(target.staleness).opacity(0.15)))
            }
            
            // Primary Human Guidance Metrics (Distance + Direction Vector)
            if let metrics = navigationMetrics, !isCurrentUser {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(metrics.distance)
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundColor(isSOS ? .red : .primary)
                        
                        Text("away")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 8) {
                        Text("\(metrics.cardinal.arrowSymbol) \(metrics.cardinal.rawValue)")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .foregroundColor(isSOS ? .red : .orange)
                        
                        Text("• Bearing \(String(format: "%.0f°", metrics.bearing)) \(metrics.cardinal.abbreviation)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.2)))
            }
            
            // Secondary Collapsible Raw Coordinates (For Technical / Search-and-Rescue Use)
            if showRawCoordinates {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "LAT: %.6f°", latitude))
                    Text(String(format: "LON: %.6f°", longitude))
                    if let acc = accuracy {
                        Text(String(format: "ACC: ±%.1f m", acc))
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.15)))
            }
            
            // Action Buttons
            HStack(spacing: 8) {
                if !isCurrentUser {
                    // Primary Navigation CTA
                    Button(action: {
                        isNavigatingPresented = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "location.north.line.fill")
                                .font(.system(size: 13, weight: .black))
                            Text("NAVIGATE TO \(senderName.uppercased())")
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isSOS ? Color.red : Color.orange)
                        .cornerRadius(10)
                    }
                }
                
                // Toggle Raw Coordinates Button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showRawCoordinates.toggle()
                    }
                }) {
                    Image(systemName: showRawCoordinates ? "chevron.up.circle" : "info.circle")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isCurrentUser ? .white.opacity(0.8) : .secondary)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                }
            }
        }
        .padding(12)
        .background(
            isCurrentUser
            ? AnyShapeStyle(AppTheme.primaryGradient)
            : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .cornerRadius(16)
        .frame(maxWidth: 290)
        .fullScreenCover(isPresented: $isNavigatingPresented) {
            OfflineNavigationView(target: target)
        }
    }
    
    private func stalenessColor(_ staleness: TargetStaleness) -> Color {
        switch staleness {
        case .live: return .green
        case .recent: return .yellow
        case .stale: return .orange
        case .expired: return .red
        }
    }
}
