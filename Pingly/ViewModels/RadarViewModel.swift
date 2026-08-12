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
    @Published var broadcastName: String
    @Published var isConnectingToPeer: Bool = false
    
    private let multipeerService: MultipeerService
    private let bleBeaconService: BLEBeaconService
    private var cancellables = Set<AnyCancellable>()
    
    init(multipeerService: MultipeerService, bleBeaconService: BLEBeaconService) {
        self.multipeerService = multipeerService
        self.bleBeaconService = bleBeaconService
        self.broadcastName = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
        setupBindings()
    }
    
    private func setupBindings() {
        // Merge peers discovered via MultipeerConnectivity & CoreBluetooth BLE scanning with base handle deduplication
        Publishers.CombineLatest(multipeerService.connectedPeersPublisher, bleBeaconService.$discoveredBLEPeers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (mcPeers, blePeers) in
                guard let self = self else { return }
                var merged = [PeerDevice]()
                
                // Add active MultipeerConnectivity peers first
                for mc in mcPeers {
                    let mcBase = self.cleanBaseName(mc.displayName)
                    if !merged.contains(where: { self.cleanBaseName($0.displayName) == mcBase }) {
                        merged.append(mc)
                    }
                }
                
                // Add BLE peers if not already present from MultipeerConnectivity
                for ble in blePeers {
                    let bleBase = self.cleanBaseName(ble.displayName)
                    if !merged.contains(where: { self.cleanBaseName($0.displayName) == bleBase }) {
                        merged.append(ble)
                    }
                }
                
                // Sort by RSSI signal strength (strongest first)
                self.nearbyPeers = merged.sorted(by: { $0.rssi > $1.rssi })
            }
            .store(in: &cancellables)
    }
    
    private func cleanBaseName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"_\d{4}$"#, options: .regularExpression) {
            return String(trimmed[..<range.lowerBound]).lowercased()
        }
        return trimmed.lowercased()
    }


    
    func updateBroadcastName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.broadcastName = trimmed
        UserDefaults.standard.set(trimmed, forKey: Constants.StorageKeys.userHandle)
        multipeerService.startAdvertisingAndBrowsing(userHandle: trimmed, status: .normal)
        bleBeaconService.startScanningAndAdvertising(userHandle: trimmed)
    }
    
    func connectToPeer(_ peer: PeerDevice) {
        self.selectedPeer = peer
        HapticManager.mediumImpact()
        if let mcPeerID = peer.mcPeerID {
            multipeerService.connectToPeer(peerID: mcPeerID)
        }
    }
    
    func onAppear() {
        bleBeaconService.startHighFrequencyRadarScan()
    }
    
    func onDisappear() {
        bleBeaconService.stopHighFrequencyRadarScan()
    }
    
    func toggleScanning() {
        isScanning.toggle()
        if isScanning {
            multipeerService.startAdvertisingAndBrowsing(userHandle: broadcastName, status: .normal)
            bleBeaconService.startHighFrequencyRadarScan()
        } else {
            multipeerService.stopAdvertisingAndBrowsing()
            bleBeaconService.stopHighFrequencyRadarScan()
        }
    }
}


