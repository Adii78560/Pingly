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

// MARK: - String Initials Extension
extension String {
    /// Extract initials from device or user name (e.g. "John Doe" -> "JD", "Alex's Mac" -> "AM")
    var initials: String {
        let clean = self.replacingOccurrences(of: "'s", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if clean.isEmpty {
            return String(self.prefix(2)).uppercased()
        }
        if clean.count == 1 {
            return String(clean[0].prefix(2)).uppercased()
        }
        let first = clean[0].prefix(1)
        let last = clean[1].prefix(1)
        return "\(first)\(last)".uppercased()
    }
    
    /// Strips MultipeerConnectivity randomly generated vendor hash suffixes (e.g. "_D89B_9360") to yield the clean peer base handle
    var cleanBaseName: String {
        let pattern = "_([A-Fa-f0-9]{4}_[A-Fa-f0-9]{4}|\\d{4}|[A-Fa-f0-9]{8})$"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(location: 0, length: self.utf16.count)
            return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "")
        }
        return self
    }
}





// MARK: - Native iOS Settings Icon Badge (Colored rounded square with SF Symbol)
struct SettingsIconBadge: View {
    let systemName: String
    let backgroundColor: Color
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)
                .frame(width: 30, height: 30)
            
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Glassmorphic Card View Modifier
struct GlassmorphicCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var borderWidth: CGFloat
    var borderGradientColors: [Color]
    var shadowOpacity: Double
    
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Constants.UI.Colors.glassOverlay)
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: borderGradientColors),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: borderWidth
                    )
            )
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 8, x: 0, y: 4)
    }
}

extension View {
    /// Glassmorphic Card Spec modifier conforming to Section 2 specification
    func glassCardStyle(
        cornerRadius: CGFloat = Constants.UI.Metrics.radiusMedium,
        borderWidth: CGFloat = 1.0,
        borderGradientColors: [Color] = [Color.white.opacity(0.18), Color.white.opacity(0.03)],
        shadowOpacity: Double = 0.10
    ) -> some View {
        self.modifier(
            GlassmorphicCardModifier(
                cornerRadius: cornerRadius,
                borderWidth: borderWidth,
                borderGradientColors: borderGradientColors,
                shadowOpacity: shadowOpacity
            )
        )
    }
}

// MARK: - Notification Name Extensions
extension Notification.Name {
    static let didReceiveRawPTTPacket = Notification.Name("didReceiveRawPTTPacket")
    static let didReceiveChannelSync = Notification.Name("didReceiveChannelSync")
    static let didSaveVoiceTranscript = Notification.Name("didSaveVoiceTranscript")
    static let didAddPeerToMessages = Notification.Name("didAddPeerToMessages")
    static let didReceiveChatMessage = Notification.Name("didReceiveChatMessage")
}







