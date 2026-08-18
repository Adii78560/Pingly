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
    init() {
        AppLogger.multipeer.info("[AppLifecycle] Application launch")
        
        AppLogger.multipeer.info("[AppLifecycle] Persistence initialization started")
        _ = SwiftDataService.shared
        AppLogger.multipeer.info("[AppLifecycle] Persistence initialization completed")
        
        AppLogger.multipeer.info("[AppLifecycle] Device identity initialization started")
        _ = KeychainIdentityService.shared.fetchOrCreateDeviceID()
        AppLogger.multipeer.info("[AppLifecycle] Device identity initialization completed")
        
        AppLogger.multipeer.info("[AppLifecycle] Authentication state check started")
        _ = AppleSignInManager.shared
        AppLogger.multipeer.info("[AppLifecycle] Authentication state check completed")
        
        AppLogger.multipeer.info("[Onboarding] First launch check")
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "com.RaiEnterprise.Relyvo.hasLaunchedBefore")
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: "com.RaiEnterprise.Relyvo.hasLaunchedBefore")
            AppLogger.multipeer.info("[Onboarding] First launch = true")
        } else {
            AppLogger.multipeer.info("[Onboarding] First launch = false")
        }
        let hasUser = AppleSignInManager.shared.appleUserID != nil
        let onboardingRequired = AppleSignInManager.shared.authState != .authenticated
        
        AppLogger.multipeer.info("[Onboarding] Existing user detected = \(hasUser)")
        AppLogger.multipeer.info("[Onboarding] Existing device detected = true")
        AppLogger.multipeer.info("[Onboarding] Onboarding required = \(onboardingRequired)")
        
        BackgroundTaskManager.shared.registerTasks()
        BackgroundAudioSessionManager.shared.configureAudioSession()
        
        AppLogger.multipeer.info("[AppLifecycle] Main UI initialization started")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    AppLogger.multipeer.info("[AppLifecycle] Main UI initialization completed")
                }
        }
    }
}
