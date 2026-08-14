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
        static let name = "Relayn"
        static let subtitle = "Off-Grid Emergency Mesh & Radio Call"
        static let version = "1.0.0"
        static let build = "1"
        static let defaultUserHandle = "Survivor_\(String(UUID().uuidString.prefix(4)))"
    }
    
    // MARK: - Multipeer P2P Mesh Network
    enum Multipeer {
        /// Bonjour service type string (Max 15 chars, lowercase ASCII + hyphen)
        static let serviceType = "relayn-mesh"
        static let maxPeerConnections = 8
        static let pingIntervalSeconds: TimeInterval = 10.0
        static let connectionTimeoutSeconds: TimeInterval = 15.0
    }
    
    // MARK: - Mesh Hardening & Protocol Specs
    enum Mesh {
        static let currentProtocolVersion: Int = 2
        static let maxPayloadBytes: Int = 64 * 1024 // 64 KB limit for text/transcript envelopes
        static let queueExpirationDays: Int = 7     // 7 days persistent store-and-forward retention
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
    
    // MARK: - UI Design System (Colors, Metrics, Typography & Tokens)
    enum UI {
        enum Colors {
            // Adaptive Light & Dark Mode Surfaces
            static let primaryBackground = Color(UIColor.systemBackground)
            static let secondarySurface = Color(UIColor.secondarySystemBackground)
            static let tertiarySurface = Color(UIColor.tertiarySystemBackground)
            static let glassOverlay = Color(UIColor.tertiarySystemBackground).opacity(0.40)
            
            // Text Colors
            static let textPrimary = Color.primary
            static let textSecondary = Color.secondary
            static let textMuted = Color.secondary.opacity(0.6)
            
            // Brand & Tactical Status Tints
            static let systemAccent = AppTheme.tintColor
            static let statusTransmitting = AppTheme.hotMagenta
            static let statusListening = Color(UIColor.systemGreen)
            static let statusWarning = Color(UIColor.systemOrange)
            static let statusDanger = Color(UIColor.systemRed)
            
            // PTT Idle & Active Dial Colors
            static let pttIdleDark = Color(red: 0.18, green: 0.18, blue: 0.18) // #2E2E2E Tactical Idle
            static let pttActiveBlue = AppTheme.tintColor
            
            // Signature Brand Gradients
            static let brandGradient = AppTheme.primaryGradient
            static let brandGradientHorizontal = AppTheme.horizontalGradient
            
            // Border Gradients
            static let glassBorderGradient = LinearGradient(
                gradient: Gradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.03)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // Backward-Compatibility Aliases
            static var backgroundDark: Color { primaryBackground }
            static var cardBackground: Color { secondarySurface }
            static var primaryAccent: Color { AppTheme.tintColor }
            static var sosDanger: Color { statusDanger }
            static var radioActive: Color { statusTransmitting }
            static var warningOrange: Color { statusWarning }
        }

        
        enum Metrics {
            // Spacing
            static let spacingTiny: CGFloat = 4.0
            static let spacingSmall: CGFloat = 8.0
            static let spacingMedium: CGFloat = 16.0
            static let spacingLarge: CGFloat = 24.0
            static let spacingExtraLarge: CGFloat = 32.0
            
            // Corner Radii
            static let radiusSmall: CGFloat = 8.0
            static let radiusMedium: CGFloat = 12.0
            static let radiusLarge: CGFloat = 20.0
            static let radiusPill: CGFloat = 9999.0
            
            // Dimensions
            static let radarCenterDiameter: CGFloat = 100.0
            static let radarOuterRingDiameter: CGFloat = 180.0
            static let peerAvatarDiameter: CGFloat = 56.0
            static let callAvatarDiameter: CGFloat = 90.0
            static let pttTouchAreaDiameter: CGFloat = 160.0
            static let pttDialDiameter: CGFloat = 120.0
            static let actionButtonDiameter: CGFloat = 72.0
        }
        
        enum Animation {
            static let defaultSpring = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.82)
            static let radarBreathingPulse = SwiftUI.Animation.easeInOut(duration: 2.0).repeatForever(autoreverses: false)
            static let pttPressSpring = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.6)
            static let callPulse = SwiftUI.Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: false)
        }
    }
}

