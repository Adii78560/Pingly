//
//  LocationMessageCardView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 13/08/26.
//

import SwiftUI
import MapKit
import CoreLocation

/// Tactical SwiftUI Location Card displaying shared offline GPS coordinates, distance, bearing, and optional MapKit pin
struct LocationMessageCardView: View {
    let senderName: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let timestamp: Date
    let isCurrentUser: Bool
    
    @ObservedObject private var locationService = LocationService.shared
    
    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    private var formattedCoordinates: String {
        let latDirection = latitude >= 0 ? "N" : "S"
        let lonDirection = longitude >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(latitude), latDirection, abs(longitude), lonDirection)
    }
    
    private var relativeDistanceInfo: (distanceFormatted: String, bearingDirection: String)? {
        locationService.distanceAndBearingFromUser(toLat: latitude, lon: longitude)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Sender & Icon
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isCurrentUser ? Color.white.opacity(0.2) : Color.orange.opacity(0.2))
                        .frame(width: 28, height: 28)
                    
                    Image(systemName: "location.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(isCurrentUser ? .white : .orange)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(isCurrentUser ? "Your Shared Location" : "\(senderName)'s Location")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isCurrentUser ? .white : .primary)
                    
                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(isCurrentUser ? .white.opacity(0.7) : .secondary)
                }
                
                Spacer()
            }
            
            // Map Preview Pin (if supported)
            Map(position: .constant(.region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )))) {
                Annotation(senderName, coordinate: coordinate) {
                    ZStack {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 26, height: 26)
                            .shadow(radius: 4)
                        Image(systemName: "figure.walk")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(height: 120)
            .cornerRadius(12)
            .disabled(true) // Static preview pin
            
            // Coordinates & Relative Distance Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(formattedCoordinates)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(isCurrentUser ? .white : .primary)
                    
                    Spacer()
                    
                    if let acc = accuracy {
                        Text(String(format: "±%.0fm", acc))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isCurrentUser ? .white.opacity(0.8) : .secondary)
                    }
                }
                
                if let (dist, bearing) = relativeDistanceInfo, !isCurrentUser {
                    HStack(spacing: 6) {
                        Image(systemName: "location.north.line.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        
                        Text("\(dist) • Bearing \(bearing)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isCurrentUser ? .white.opacity(0.9) : .orange)
                    }
                }
            }
            
            // Button: Open in Apple Maps
            Button(action: openInAppleMaps) {
                HStack {
                    Image(systemName: "map.fill")
                    Text("Open in Apple Maps")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isCurrentUser ? .orange : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isCurrentUser ? Color.white : Color.orange)
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(
            isCurrentUser
            ? LinearGradient(colors: [Color.orange, Color(red: 0.95, green: 0.5, blue: 0.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(white: 0.15), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(16)
        .frame(maxWidth: 280)
    }
    
    private func openInAppleMaps() {
        HapticsManager.shared.lightImpact()
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = "\(senderName)'s Pingly Position"
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        ])
    }
}

#Preview {
    LocationMessageCardView(
        senderName: "Aditya",
        latitude: 37.7749,
        longitude: -122.4194,
        accuracy: 5.0,
        timestamp: Date(),
        isCurrentUser: false
    )
}
