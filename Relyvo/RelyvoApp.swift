//
//  RelyvoApp.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 16/08/26.
//

import SwiftUI
import os

@main
struct RelyvoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        
        _ = SwiftDataService.shared
        
        _ = KeychainIdentityService.shared.fetchOrCreateDeviceID()
        
        _ = AppleSignInManager.shared
        
        let initialUserID = IdentityManager.shared.accountID?.uuidString ?? UserDefaults.standard.string(forKey: "com.adityarai.pingly.accountID")
        SubscriptionManager.shared.configure(appUserID: initialUserID)
        
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "com.RaiEnterprise.Relyvo.hasLaunchedBefore")
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: "com.RaiEnterprise.Relyvo.hasLaunchedBefore")
        } else {
        }
        let hasUser = AppleSignInManager.shared.appleUserID != nil
        let onboardingRequired = AppleSignInManager.shared.authState != .authenticated
        
        
        BackgroundTaskManager.shared.registerTasks()
        BackgroundAudioSessionManager.shared.configureAudioSession()
        VoiceStorageManager.shared.startStorageMonitoring()
        
        
        // Run self-testing verification suite on launch
        Task {
            _ = await RelaynHardeningTests.shared.runAllVerificationTests()
            Task { @MainActor in
                _ = NavigationEngineTests.shared.runAllNavigationTests()
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        SubscriptionManager.shared.refreshStateOnForeground()
                    }
                }
        }
    }
}
