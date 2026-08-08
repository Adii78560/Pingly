//
//  BLEBeaconService.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import CoreBluetooth
import Combine
import os

/// Production CoreBluetooth service for low-power beaconing and RSSI radar scanning
final class BLEBeaconService: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published private(set) var discoveredBLEPeers: [PeerDevice] = []
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    
    private var userHandle: String = Constants.App.defaultUserHandle
    
    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    func startScanningAndAdvertising(userHandle: String) {
        self.userHandle = userHandle
        
        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(
                withServices: [Constants.BLE.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            AppLogger.ble.info("Started BLE RSSI Scanning for Pingly beacons")
        }
        
        if peripheralManager.state == .poweredOn {
            let advertisementData: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey: [Constants.BLE.serviceUUID],
                CBAdvertisementDataLocalNameKey: userHandle
            ]
            peripheralManager.startAdvertising(advertisementData)
            AppLogger.ble.info("Started BLE Beacon Advertising as \(userHandle)")
        }
    }
    
    func stopScanningAndAdvertising() {
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
