//
//  EmergencyStatus.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Emergency status levels for Relayn mesh nodes
enum EmergencyStatus: String, Codable, CaseIterable, Identifiable {
    case normal = "Normal Operations"
    case mountainSOS = "Mountain / Trekking Rescue"
    case medicalEmergency = "Medical SOS"
    case warDisasterAlert = "War / Disaster Zone Alert"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .normal:
            return "checkmark.shield.fill"
        case .mountainSOS:
            return "mountain.2.fill"
        case .medicalEmergency:
            return "cross.case.fill"
        case .warDisasterAlert:
            return "exclamationmark.triangle.fill"
        }
    }
    
    var themeColor: Color {
        switch self {
        case .normal:
            return Constants.UI.Colors.primaryAccent
        case .mountainSOS:
            return Constants.UI.Colors.warningOrange
        case .medicalEmergency:
            return Constants.UI.Colors.sosDanger
        case .warDisasterAlert:
            return Color.purple
        }
    }
    
    var priorityLevel: Int {
        switch self {
        case .normal: return 0
        case .mountainSOS: return 2
        case .medicalEmergency: return 3
        case .warDisasterAlert: return 4
        }
    }
}
