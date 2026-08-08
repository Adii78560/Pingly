//
//  Extensions.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import CoreLocation

// MARK: - Date Formatting Extension
extension Date {
    /// Format timestamp into short emergency log string (e.g., "14:23:05")
    var logTimeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: self)
    }
    
    /// Relative time ago description (e.g., "2m ago", "Just now")
    var relativeTimeAgo: String {
        let seconds = Int(Date().timeIntervalSince(self))
        if seconds < 5 { return "Just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}

// MARK: - Double RSSI Distance Calculation
extension Double {
    /// Estimate distance in meters from BLE RSSI value using standard log-distance path loss model
    static func estimatedDistance(fromRSSI rssi: Int) -> Double {
        guard rssi < 0 else { return 0.0 }
        let txPower = Constants.BLE.rssiReferenceAt1Meter
        let ratio = (txPower - Double(rssi)) / (10.0 * Constants.BLE.pathLossExponent)
        return pow(10.0, ratio)
    }
}

// MARK: - CLLocationCoordinate2D Formatting
extension CLLocationCoordinate2D {
    var formattedCoordinates: String {
        return String(format: "%.4f° N, %.4f° E", latitude, longitude)
    }
}

// MARK: - View Modifiers
extension View {
    /// Glassmorphism tactical card style
    func glassCardStyle(backgroundColor: Color = Constants.UI.Colors.cardBackground) -> some View {
        self
            .padding(Constants.UI.Layout.cardPadding)
            .background(backgroundColor.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: Constants.UI.Layout.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.UI.Layout.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}
