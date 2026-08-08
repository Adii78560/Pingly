//
//  SettingsViewModel.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import Combine

/// View model driving user emergency identity, BLE/Wi-Fi settings, and diagnostics
final class SettingsViewModel: ObservableObject {
    
    @Published var userHandle: String {
        didSet {
            UserDefaults.standard.set(userHandle, forKey: Constants.StorageKeys.userHandle)
        }
    }
    
    @Published var selectedEmergencyStatus: EmergencyStatus {
        didSet {
            UserDefaults.standard.set(selectedEmergencyStatus.rawValue, forKey: Constants.StorageKeys.emergencyStatus)
        }
    }
    
    @Published var isLowPowerModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isLowPowerModeEnabled, forKey: Constants.StorageKeys.isLowPowerModeEnabled)
        }
    }
    
    private let multipeerService: MultipeerService
    private let bleBeaconService: BLEBeaconService
    
    init(multipeerService: MultipeerService, bleBeaconService: BLEBeaconService) {
        self.multipeerService = multipeerService
        self.bleBeaconService = bleBeaconService
        
        let storedHandle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        let storedStatusRaw = UserDefaults.standard.string(forKey: Constants.StorageKeys.emergencyStatus) ?? EmergencyStatus.normal.rawValue
        
        self.userHandle = storedHandle
        self.selectedEmergencyStatus = EmergencyStatus(rawValue: storedStatusRaw) ?? .normal
        self.isLowPowerModeEnabled = UserDefaults.standard.bool(forKey: Constants.StorageKeys.isLowPowerModeEnabled)
    }
    
    func applySettings() {
        multipeerService.startAdvertisingAndBrowsing(userHandle: userHandle, status: selectedEmergencyStatus)
        bleBeaconService.startScanningAndAdvertising(userHandle: userHandle)
    }
}
