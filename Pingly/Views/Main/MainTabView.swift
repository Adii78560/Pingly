//
//  MainTabView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Main Tab Navigation Host View for Pingly Off-Grid Emergency Mesh
struct MainTabView: View {
    
    // MARK: - Core Services (Singletons / StateObjects)
    @StateObject private var multipeerService = MultipeerService()
    @StateObject private var bleBeaconService = BLEBeaconService()
    @StateObject private var radioAudioService = RadioAudioService()
    @StateObject private var locationService = LocationService()
    
    // MARK: - ViewModels
    @StateObject private var radarViewModel: RadarViewModel
    @StateObject private var messagesViewModel: MessagesViewModel
    @StateObject private var radioCallViewModel: RadioCallViewModel
    @StateObject private var settingsViewModel: SettingsViewModel
    
    init() {
        let mpService = MultipeerService()
        let bleService = BLEBeaconService()
        let audioService = RadioAudioService()
        let locService = LocationService()
        
        _multipeerService = StateObject(wrappedValue: mpService)
        _bleBeaconService = StateObject(wrappedValue: bleService)
        _radioAudioService = StateObject(wrappedValue: audioService)
        _locationService = StateObject(wrappedValue: locService)
        
        _radarViewModel = StateObject(wrappedValue: RadarViewModel(multipeerService: mpService, bleBeaconService: bleService))
        _messagesViewModel = StateObject(wrappedValue: MessagesViewModel(multipeerService: mpService, locationService: locService))
        _radioCallViewModel = StateObject(wrappedValue: RadioCallViewModel(multipeerService: mpService, audioService: audioService))
        _settingsViewModel = StateObject(wrappedValue: SettingsViewModel(multipeerService: mpService, bleBeaconService: bleService))
        
        // Custom Dark Mode TabBar Appearance
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1.0)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    
    var body: some View {
        TabView {
            RadarView(viewModel: radarViewModel)
                .tabItem {
                    Label("Radar", systemImage: "dot.radiowaves.left.and.right")
                }
            
            MessagesView(viewModel: messagesViewModel)
                .tabItem {
                    Label("Signal Drop", systemImage: "tray.full.fill")
                }
            
            RadioCallView(viewModel: radioCallViewModel)
                .tabItem {
                    Label("Radio PTT", systemImage: "mic.fill")
                }
            
            SettingsView(viewModel: settingsViewModel)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(Constants.UI.Colors.primaryAccent)
        .onAppear {
            locationService.requestLocationPermission()
            let handle = settingsViewModel.userHandle
            multipeerService.startAdvertisingAndBrowsing(userHandle: handle, status: settingsViewModel.selectedEmergencyStatus)
            bleBeaconService.startScanningAndAdvertising(userHandle: handle)
        }
    }
}
