//
//  NavigationState.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import Foundation
import CoreLocation

/// 8-Sector Cardinal and Intercardinal compass bearings
enum CardinalDirection: String, CaseIterable, Sendable {
    case north = "NORTH"
    case northEast = "NORTHEAST"
    case east = "EAST"
    case southEast = "SOUTHEAST"
    case south = "SOUTH"
    case southWest = "SOUTHWEST"
    case west = "WEST"
    case northWest = "NORTHWEST"
    
    var abbreviation: String {
        switch self {
        case .north: return "N"
        case .northEast: return "NE"
        case .east: return "E"
        case .southEast: return "SE"
        case .south: return "S"
        case .southWest: return "SW"
        case .west: return "W"
        case .northWest: return "NW"
        }
    }
    
    var arrowSymbol: String {
        switch self {
        case .north: return "↑"
        case .northEast: return "↗"
        case .east: return "→"
        case .southEast: return "↘"
        case .south: return "↓"
        case .southWest: return "↙"
        case .west: return "←"
        case .northWest: return "↖"
        }
    }
    
    /// Initializes cardinal direction from bearing angle (0...360)
    init(bearing: Double) {
        let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch normalized {
        case 337.5...360.0, 0.0..<22.5:
            self = .north
        case 22.5..<67.5:
            self = .northEast
        case 67.5..<112.5:
            self = .east
        case 112.5..<157.5:
            self = .southEast
        case 157.5..<202.5:
            self = .south
        case 202.5..<247.5:
            self = .southWest
        case 247.5..<292.5:
            self = .west
        case 292.5..<337.5:
            self = .northWest
        default:
            self = .north
        }
    }
}

/// Human-understandable navigation instructions derived from relative heading offset
enum NavigationInstruction: Equatable, Sendable {
    case arrived
    case faceTarget
    case turnSlightlyRight(degrees: Int)
    case turnRight(degrees: Int)
    case turnSharplyRight(degrees: Int)
    case turnSlightlyLeft(degrees: Int)
    case turnLeft(degrees: Int)
    case turnSharplyLeft(degrees: Int)
    case turnAround(degrees: Int)
    case acquiringSignal
    case locationExpired
    
    var text: String {
        switch self {
        case .arrived:
            return "ARRIVED AT TARGET"
        case .faceTarget:
            return "ON TARGET"
        case .turnSlightlyRight(let deg):
            return "Turn slightly right \(deg)°"
        case .turnRight(let deg):
            return "Turn right \(deg)°"
        case .turnSharplyRight(let deg):
            return "Turn sharply right \(deg)°"
        case .turnSlightlyLeft(let deg):
            return "Turn slightly left \(deg)°"
        case .turnLeft(let deg):
            return "Turn left \(deg)°"
        case .turnSharplyLeft(let deg):
            return "Turn sharply left \(deg)°"
        case .turnAround(let deg):
            return "Turn around (\(deg)°)"
        case .acquiringSignal:
            return "Acquiring GPS fix..."
        case .locationExpired:
            return "Target signal lost"
        }
    }
    
    var iconName: String {
        switch self {
        case .arrived:
            return "checkmark.circle.fill"
        case .faceTarget:
            return "arrow.up.circle.fill"
        case .turnSlightlyRight, .turnRight:
            return "arrow.turn.up.right"
        case .turnSharplyRight:
            return "arrow.right.circle.fill"
        case .turnSlightlyLeft, .turnLeft:
            return "arrow.turn.up.left"
        case .turnSharplyLeft:
            return "arrow.left.circle.fill"
        case .turnAround:
            return "arrow.uturn.down.circle.fill"
        case .acquiringSignal:
            return "antenna.radiowaves.left.and.right"
        case .locationExpired:
            return "exclamationmark.triangle.fill"
        }
    }
}

/// Full computed state vector between device and active navigation target
struct RelativeNavigationVector: Sendable, Equatable {
    let distanceMeters: Double
    let initialBearingDegrees: Double
    let relativeBearingDegrees: Double  // Offset from device's continuous heading (-180...+180)
    let userHeadingDegrees: Double
    let cardinal: CardinalDirection
    let instruction: NavigationInstruction
    let isAligned: Bool                 // Within ±10 degrees
    let isArrived: Bool                 // Within 10 meters
    let distanceTrend: DistanceTrend    // Closing, Opening, or Constant
    let formattedDistance: String
    
    enum DistanceTrend: String, Sendable {
        case closing = "CLOSING"
        case opening = "OPENING"
        case stationary = "STABLE"
    }
}
