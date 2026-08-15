//
//  ATTManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 13/08/26.
//

import Foundation
import AppTrackingTransparency
import AdSupport
import Combine
import UIKit
import os

/// Senior iOS Manager for App Tracking Transparency (ATT) lifecycle and status management
final class ATTManager: ObservableObject {
    static let shared = ATTManager()
    
    private let attStorageKey = "com.adityarai.pingly.hasPromptedATT"
    
    @Published private(set) var trackingStatus: ATTrackingManager.AuthorizationStatus = .notDetermined
    
    /// Indicates whether Relayn uses 3rd-party tracking SDKs.
    /// Relayn is an off-grid P2P mesh network using zero 3rd-party ad/tracking SDKs.
    let isTrackingRequiredBySDKs: Bool = false
    
    private init() {
        updateTrackingStatus()
    }
    
    /// Refreshes current ATT authorization status from iOS ATTrackingManager
    func updateTrackingStatus() {
        DispatchQueue.main.async {
            self.trackingStatus = ATTrackingManager.trackingAuthorizationStatus
        }
    }
    
    /// Requests App Tracking Transparency permission EXACTLY ONCE upon initial app launch/install.
    /// Complies strictly with Apple App Store Review Guidelines.
    func requestTrackingPermissionIfFirstLaunch(completion: ((ATTrackingManager.AuthorizationStatus) -> Void)? = nil) {
        let hasPrompted = UserDefaults.standard.bool(forKey: attStorageKey)
        
        // If already prompted or status is determined by iOS, return immediately without re-triggering
        guard !hasPrompted else {
            completion?(ATTrackingManager.trackingAuthorizationStatus)
            return
        }
        
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
            UserDefaults.standard.set(true, forKey: attStorageKey)
            completion?(ATTrackingManager.trackingAuthorizationStatus)
            return
        }
        
        // Mark as prompted in persistent store so the banner will NEVER show a second time
        UserDefaults.standard.set(true, forKey: attStorageKey)
        
        // 1.2s delay ensures UI navigation & splash screen transition finish before presenting system sheet
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            ATTrackingManager.requestTrackingAuthorization { status in
                DispatchQueue.main.async {
                    self.trackingStatus = status
                    AppLogger.multipeer.info("ATT Tracking Authorization status updated ONCE: \(status.rawValue)")
                    completion?(status)
                }
            }
        }
    }
    
    /// Formatted status description for UI settings
    var statusDescription: String {
        switch trackingStatus {
        case .notDetermined:
            return "Not Determined"
        case .restricted:
            return "Restricted (System Controlled)"
        case .denied:
            return "Denied (Zero Ad Tracking)"
        case .authorized:
            return "Authorized"
        @unknown default:
            return "Unknown"
        }
    }
}
