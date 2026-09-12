//
//  NavigationTarget.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import Foundation
import CoreLocation

/// Type classification for off-grid navigation targets
enum NavigationTargetType: String, Codable, CaseIterable, Sendable {
    case peer           // Active Relyvo mesh peer / contact
    case sos            // High-priority emergency distress beacon
    case returnToStart  // Starting breadcrumb origin point
    case waypoint       // User marked tactical waypoint
    
    var iconName: String {
        switch self {
        case .peer: return "person.fill"
        case .sos: return "sos.circle.fill"
        case .returnToStart: return "arrow.uturn.backward.circle.fill"
        case .waypoint: return "mappin.and.ellipse"
        }
    }
}

/// Staleness classification of a target's received coordinates
enum TargetStaleness: Sendable {
    case live       // < 15 seconds
    case recent     // 15 - 60 seconds
    case stale      // 1 - 5 minutes
    case expired    // > 5 minutes
    
    var badgeTitle: String {
        switch self {
        case .live: return "LIVE"
        case .recent: return "RECENT"
        case .stale: return "STALE"
        case .expired: return "EXPIRED"
        }
    }
    
    var isTrustworthy: Bool {
        switch self {
        case .live, .recent: return true
        case .stale: return true
        case .expired: return false
        }
    }
}

/// Universal domain model for navigation targets decoupled from chat/messaging layers.
struct NavigationTarget: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let coordinate: CLLocationCoordinate2D
    let altitude: Double?
    let accuracy: Double
    let timestamp: Date
    let speed: Double?
    let course: Double?
    let sequenceNumber: Int
    let targetType: NavigationTargetType
    
    init(
        id: String,
        displayName: String,
        coordinate: CLLocationCoordinate2D,
        altitude: Double? = nil,
        accuracy: Double = 5.0,
        timestamp: Date = Date(),
        speed: Double? = nil,
        course: Double? = nil,
        sequenceNumber: Int = 0,
        targetType: NavigationTargetType = .peer
    ) {
        self.id = id
        self.displayName = displayName
        self.coordinate = coordinate
        self.altitude = altitude
        self.accuracy = accuracy
        self.timestamp = timestamp
        self.speed = speed
        self.course = course
        self.sequenceNumber = sequenceNumber
        self.targetType = targetType
    }
    
    /// Calculate current staleness state relative to now
    var staleness: TargetStaleness {
        let age = Date().timeIntervalSince(timestamp)
        if age < 15 {
            return .live
        } else if age < 60 {
            return .recent
        } else if age < 300 {
            return .stale
        } else {
            return .expired
        }
    }
    
    /// Human-friendly representation of data freshness
    var humanAgeDescription: String {
        let age = Int(Date().timeIntervalSince(timestamp))
        if age < 5 {
            return "Updated just now"
        } else if age < 60 {
            return "Updated \(age)s ago"
        } else if age < 3600 {
            let minutes = max(1, age / 60)
            return "Updated \(minutes)m ago"
        } else {
            return "Location expired"
        }
    }
    
    static func == (lhs: NavigationTarget, rhs: NavigationTarget) -> Bool {
        return lhs.id == rhs.id &&
            lhs.displayName == rhs.displayName &&
            lhs.coordinate.latitude == rhs.coordinate.latitude &&
            lhs.coordinate.longitude == rhs.coordinate.longitude &&
            lhs.timestamp == rhs.timestamp &&
            lhs.sequenceNumber == rhs.sequenceNumber &&
            lhs.targetType == rhs.targetType
    }
}
