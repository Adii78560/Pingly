//
//  RadarViewModel.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import Combine

/// View model driving the Proximity Radar screen
final class RadarViewModel: ObservableObject {
    
    @Published var nearbyPeers: [PeerDevice] = []
    @Published var isScanning: Bool = true
    @Published var selectedPeer: PeerDevice?
    
    private let multipeerService: MultipeerService
    private let bleBeaconService: BLEBeaconService
    private var cancellables = Set<AnyCancellable>()
    
    init(multipeerService: MultipeerService, bleBeaconService: BLEBeaconService) {
        self.multipeerService = multipeerService
        self.bleBeaconService = bleBeaconService
        setupBindings()
    }
    
    private func setupBindings() {
        // Merge peers discovered via MultipeerConnectivity & CoreBluetooth BLE scanning
        Publishers.CombineLatest(multipeerService.connectedPeersPublisher, bleBeaconService.$discoveredBLEPeers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (mcPeers, blePeers) in
                guard let self = self else { return }
                var merged = mcPeers
                for ble in blePeers {
                    if !merged.contains(where: { $0.id == ble.id || $0.displayName == ble.displayName }) {
                        merged.append(ble)
                    }
                }
                // Sort by RSSI signal strength (strongest first)
                self.nearbyPeers = merged.sorted(by: { $0.rssi > $1.rssi })
            }
            .store(in: &cancellables)
    }
    
    func toggleScanning() {
        isScanning.toggle()
        if isScanning {
            let handle = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
            multipeerService.startAdvertisingAndBrowsing(userHandle: handle, status: .normal)
            bleBeaconService.startScanningAndAdvertising(userHandle: handle)
        } else {
            multipeerService.stopAdvertisingAndBrowsing()
            bleBeaconService.stopScanningAndAdvertising()
        }
    }
}
