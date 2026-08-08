//
//  MainTabView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Main Tab Navigation Host View for RadioFy / Pingly
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
    
    // Splash Screen State
    @State private var isSplashFinished = false
    @State private var showIncomingCallSheet = false
    @State private var incomingPeerName = "Rahul's iPhone"
    @State private var selectedTab = 0
    
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
    }
    
    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                RadarView(viewModel: radarViewModel)
                    .tabItem {
                        Label("Radar", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .tag(0)
                
                RadioCallView(viewModel: radioCallViewModel)
                    .tabItem {
                        Label("Walkie-Talkie", systemImage: "waveform")
                    }
                    .tag(1)
                
                MessagesView(viewModel: messagesViewModel)
                    .tabItem {
                        Label("Messages", systemImage: "message.fill")
                    }
                    .tag(2)
                
                SettingsView(viewModel: settingsViewModel)
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                    .tag(3)
            }
            .tint(.orange)

            
            if !isSplashFinished {
                AnimatedSplashScreenView(isFinished: $isSplashFinished)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .fullScreenCover(isPresented: $showIncomingCallSheet) {
            IncomingRequestView(
                peerName: incomingPeerName,
                rssi: -45,
                channelName: "SECURE-07",
                onAccept: {
                    showIncomingCallSheet = false
                    selectedTab = 1 // Switch to Walkie-Talkie tab
                },
                onDecline: {
                    showIncomingCallSheet = false
                }
            )
        }
        .onAppear {
            locationService.requestLocationPermission()
            let handle = settingsViewModel.userHandle
            multipeerService.startAdvertisingAndBrowsing(userHandle: handle, status: settingsViewModel.selectedEmergencyStatus)
            bleBeaconService.startScanningAndAdvertising(userHandle: handle)
        }
    }
}


