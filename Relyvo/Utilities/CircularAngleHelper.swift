//
//  CircularAngleHelper.swift
//  Relayn
//
//  Created by Senior iOS Developer on 14/08/26.
//

import Foundation

/// Pure mathematical helper for circular angle calculations and shortest path interpolation
public enum CircularAngleHelper {
    
    /// Calculates the shortest signed angular difference from oldAngle to newAngle in degrees [-180.0, +180.0].
    /// Examples:
    /// - 359° -> 1° = +2.0°
    /// - 1° -> 359° = -2.0°
    /// - 350° -> 10° = +20.0°
    /// - 10° -> 350° = -20.0°
    /// - 179° -> 181° = +2.0°
    public static func shortestAngularDifference(from oldAngle: Double, to newAngle: Double) -> Double {
        let delta = (newAngle - oldAngle + 540.0).truncatingRemainder(dividingBy: 360.0) - 180.0
        return delta
    }
}
