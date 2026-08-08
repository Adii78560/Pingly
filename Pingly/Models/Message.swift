//
//  Message.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import CoreLocation

/// Emergency message drop & store-and-forward mesh payload model
struct Message: Identifiable, Codable, Hashable {
    let id: UUID
    let senderID: String
    let senderName: String
    let text: String
    let timestamp: Date
    let latitude: Double?
    let longitude: Double?
    let isSOS: Bool
    let emergencyStatus: EmergencyStatus
    var hopsCount: Int
    
    init(
        id: UUID = UUID(),
        senderID: String,
        senderName: String,
        text: String,
        timestamp: Date = Date(),
        latitude: Double? = nil,
        longitude: Double? = nil,
        isSOS: Bool = false,
        emergencyStatus: EmergencyStatus = .normal,
        hopsCount: Int = 0
    ) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.text = text
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.isSOS = isSOS
        self.emergencyStatus = emergencyStatus
        self.hopsCount = hopsCount
    }
    
    var formattedLocation: String? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return String(format: "%.4f° N, %.4f° E", lat, lon)
    }
}
