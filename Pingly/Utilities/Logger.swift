//
//  Logger.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import os

/// Production Logger wrapper using Swift `os.Logger` for unified, high-performance structured logging.
enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.RaiEnterprise.Pingly"
    
    static let general = Logger(subsystem: subsystem, category: "General")
    static let multipeer = Logger(subsystem: subsystem, category: "MultipeerMesh")
    static let ble = Logger(subsystem: subsystem, category: "BLEBeacon")
    static let audio = Logger(subsystem: subsystem, category: "RadioAudio")
    static let location = Logger(subsystem: subsystem, category: "Location")
    static let emergency = Logger(subsystem: subsystem, category: "EmergencySOS")
}
