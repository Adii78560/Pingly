//
//  MainTabView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI
import os

/// Main Tab Navigation Host View for RadioFy / Pingly
struct MainTabView: View {

    
    @Environment(\.scenePhase) private var scenePhase
    
    // MARK: - Core Services (Singletons)
    @StateObject private var multipeerService = MultipeerService.shared

    @StateObject private var bleBeaconService = BLEBeaconService.shared
    @StateObject private var radioAudioService = RadioAudioService.shared
    @StateObject private var locationService = LocationService.shared
    
    // MARK: - ViewModels
    @StateObject private var radarViewModel: RadarViewModel
    @StateObject private var messagesViewModel: MessagesViewModel
    @StateObject private var radioCallViewModel: RadioCallViewModel
    @StateObject private var settingsViewModel: SettingsViewModel
    
    // Splash Screen State
    @State private var isSplashFinished = false
    @State private var showIncomingCallSheet = false
    @State private var incomingPeerName = "Nearby Pingly Node"
    @State private var selectedTab = 0

    
    init() {
        let mp = MultipeerService.shared
        let ble = BLEBeaconService.shared
        let audio = RadioAudioService.shared
        let loc = LocationService.shared
        
        _radarViewModel = StateObject(wrappedValue: RadarViewModel(multipeerService: mp, bleBeaconService: ble))
        _messagesViewModel = StateObject(wrappedValue: MessagesViewModel(multipeerService: mp, locationService: loc))
        _radioCallViewModel = StateObject(wrappedValue: RadioCallViewModel(multipeerService: mp, audioService: audio))
        _settingsViewModel = StateObject(wrappedValue: SettingsViewModel(multipeerService: mp, bleBeaconService: ble))
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
            ATTManager.shared.requestTrackingPermissionIfFirstLaunch()
            locationService.requestLocationPermission()
            let handle = settingsViewModel.userHandle
            multipeerService.startAdvertisingAndBrowsing(userHandle: handle, status: settingsViewModel.selectedEmergencyStatus)
            bleBeaconService.startScanningAndAdvertising(userHandle: handle, allowDuplicates: false)
        }

        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                bleBeaconService.pauseScanningForBackground()
                AppLogger.multipeer.info("App entered background. Throttled BLE scanning to conserve battery.")
            case .active:
                bleBeaconService.resumeScanningForForeground()
                MultipeerService.shared.flushPendingStoreAndForwardQueue()
                AppLogger.multipeer.info("App active in foreground. Resumed discovery & triggered coalesced queue flush.")
            default:
                break
            }
        }

    }
}



