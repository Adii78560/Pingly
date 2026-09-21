//
//  BLEBeaconService.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import CoreBluetooth
import Combine
import os

/// Production CoreBluetooth service for low-power beaconing and RSSI radar scanning
final class BLEBeaconService: NSObject, ObservableObject {
    
    static let shared = BLEBeaconService()
    
    // MARK: - Published Properties

    @Published private(set) var discoveredBLEPeers: [PeerDevice] = []
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    
    private var userHandle: String = Constants.App.defaultUserHandle
    
    private var isHighFrequencyRadarActive = false
    
    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    func startScanningAndAdvertising(userHandle: String, allowDuplicates: Bool = false) {
        self.userHandle = userHandle
        
        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(
                withServices: [Constants.BLE.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
            )
        }
        
        if peripheralManager.state == .poweredOn {
            let advertisementData: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey: [Constants.BLE.serviceUUID],
                CBAdvertisementDataLocalNameKey: userHandle
            ]
            peripheralManager.startAdvertising(advertisementData)
        }
    }
    
    /// Enables high-frequency RSSI duplicate scanning for live Radar view
    func startHighFrequencyRadarScan() {
        guard !isHighFrequencyRadarActive else { return }
        isHighFrequencyRadarActive = true
        startScanningAndAdvertising(userHandle: userHandle, allowDuplicates: true)
    }
    
    /// Reverts to low-power BLE scanning when leaving Radar view
    func stopHighFrequencyRadarScan() {
        guard isHighFrequencyRadarActive else { return }
        isHighFrequencyRadarActive = false
        startScanningAndAdvertising(userHandle: userHandle, allowDuplicates: false)
    }
    
    /// Pauses scanning during app background transitions to preserve battery
    func pauseScanningForBackground() {
        centralManager.stopScan()
    }
    
    /// Resumes scanning when app returns to foreground
    func resumeScanningForForeground() {
        startScanningAndAdvertising(userHandle: userHandle, allowDuplicates: isHighFrequencyRadarActive)
    }
    
    func stopScanningAndAdvertising() {
        isHighFrequencyRadarActive = false
        centralManager.stopScan()
        peripheralManager.stopAdvertising()
    }
}


// MARK: - CBCentralManagerDelegate
extension BLEBeaconService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            self.bluetoothState = central.state
            if central.state == .poweredOn {
                self.startScanningAndAdvertising(userHandle: self.userHandle)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Survivor_\(peripheral.identifier.uuidString.prefix(4))"
        let rssiValue = RSSI.intValue
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = self.discoveredBLEPeers.firstIndex(where: { $0.id == peripheral.identifier.uuidString }) {
                self.discoveredBLEPeers[index].rssi = rssiValue
                self.discoveredBLEPeers[index].estimatedDistanceMeters = Double.estimatedDistance(fromRSSI: rssiValue)
                self.discoveredBLEPeers[index].lastSeen = Date()
            } else {
                let newPeer = PeerDevice(
                    id: peripheral.identifier.uuidString,
                    displayName: name,
                    rssi: rssiValue,
                    emergencyStatus: .normal,
                    lastSeen: Date(),
                    isConnected: false
                )
                self.discoveredBLEPeers.append(newPeer)
            }
        }
    }
}

// MARK: - CBPeripheralManagerDelegate
extension BLEBeaconService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            let advertisementData: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey: [Constants.BLE.serviceUUID],
                CBAdvertisementDataLocalNameKey: userHandle
            ]
            peripheral.startAdvertising(advertisementData)
        }
    }
}
