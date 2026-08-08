//
//  Constants.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import SwiftUI
import CoreBluetooth

/// Production Constants namespace for the Pingly emergency off-grid mesh app.
enum Constants {
    
    // MARK: - App Identity
    enum App {
        static let name = "Pingly"
        static let subtitle = "Off-Grid Emergency Mesh & Radio Call"
        static let version = "1.0.0"
        static let build = "1"
        static let defaultUserHandle = "Survivor_\(String(UUID().uuidString.prefix(4)))"
    }
    
    // MARK: - Multipeer P2P Mesh Network
    enum Multipeer {
        /// Bonjour service type string (Max 15 chars, lowercase ASCII + hyphen)
        static let serviceType = "pingly-mesh"
        static let maxPeerConnections = 8
        static let pingIntervalSeconds: TimeInterval = 10.0
        static let connectionTimeoutSeconds: TimeInterval = 15.0
    }
    
    // MARK: - Bluetooth Low Energy (BLE)
    enum BLE {
        /// Custom 128-bit UUID for Pingly SOS Mesh Discovery
        static let serviceUUID = CBUUID(string: "A4950001-C5B1-4B44-B512-1370F02A74DA")
        static let characteristicUUID = CBUUID(string: "A4950002-C5B1-4B44-B512-1370F02A74DA")
        static let rssiReferenceAt1Meter: Double = -59.0 // Standard BLE reference RSSI for distance estimation
        static let pathLossExponent: Double = 2.5        // Outdoor / obstacle attenuation factor
    }
    
    // MARK: - Push-To-Talk (PTT) Radio Audio
    enum Audio {
        static let sampleRate: Double = 16000.0          // 16kHz for speech efficiency over mesh
        static let channels: UInt32 = 1                  // Mono speech stream
        static let bitsPerChannel: UInt32 = 16
        static let bufferSize: UInt32 = 1024
        static let pttMaxDurationSeconds: TimeInterval = 60.0
    }
    
    // MARK: - Emergency SOS & Signal Dropping
    enum Emergency {
        static let broadcastTTL: Int = 5                 // Max mesh node hops
        static let sosBeaconInterval: TimeInterval = 5.0 // Seconds between auto SOS pings
    }
    
    // MARK: - Storage Keys (UserDefaults)
    enum StorageKeys {
        static let userHandle = "pingly_user_handle"
        static let emergencyStatus = "pingly_emergency_status"
        static let isLowPowerModeEnabled = "pingly_low_power_mode"
        static let emergencyContacts = "pingly_emergency_contacts"
        static let savedMessages = "pingly_saved_messages"
    }
    
    // MARK: - UI Design System (Colors & Layout)
    enum UI {
        enum Colors {
            static let backgroundDark = Color(red: 0.07, green: 0.09, blue: 0.12) // #12171F Tactical Dark
            static let cardBackground = Color(red: 0.12, green: 0.15, blue: 0.20) // #1F2633 Glass Card
            static let primaryAccent = Color(red: 0.18, green: 0.80, blue: 0.44)  // Emerald Green Mesh Online
            static let sosDanger = Color(red: 0.93, green: 0.26, blue: 0.26)       // Crimson Red Emergency
            static let radioActive = Color(red: 0.20, green: 0.60, blue: 1.00)     // Electric Blue PTT Radio
            static let warningOrange = Color(red: 1.00, green: 0.60, blue: 0.00)   // Tactical Amber Warning
            static let textPrimary = Color.white
            static let textSecondary = Color(white: 0.70)
            static let textMuted = Color(white: 0.45)
        }
        
        enum Layout {
            static let cornerRadius: CGFloat = 16.0
            static let cardPadding: CGFloat = 16.0
            static let standardSpacing: CGFloat = 12.0
            static let iconSizeLarge: CGFloat = 28.0
            static let radarDiameter: CGFloat = 280.0
        }
        
        enum Animation {
            static let defaultSpring = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.75)
            static let radarPulse = SwiftUI.Animation.linear(duration: 2.5).repeatForever(autoreverses: false)
            static let pttGlow = SwiftUI.Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
        }
    }
}
