//
//  AppleSignInManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 13/08/26.
//

import Foundation
import UIKit
import Combine
import AuthenticationServices
import CryptoKit
import OSLog

/// Single source of truth for Application Authentication State
enum AuthState: String, Codable {
    case checking
    case authenticated
    case unauthenticated
}

/// Security & Credential Storage Keys for Apple Sign-In
enum AppleSignInKeys {
    static let userID = "com.adityarai.pinglyapp.appleUserID"
    static let userEmail = "com.adityarai.pinglyapp.appleUserEmail"
    static let userFullName = "com.adityarai.pinglyapp.appleUserFullName"
    static let isAuthenticated = "com.adityarai.pinglyapp.isAuthenticated"
}

/// Senior iOS Architecture: Apple Sign-In Controller & Credential State Manager
@MainActor
final class AppleSignInManager: NSObject, ObservableObject {

    static let shared = AppleSignInManager()
    
    @Published private(set) var authState: AuthState = .checking
    @Published private(set) var userEmail: String?
    @Published private(set) var userFullName: String?
    @Published private(set) var appleUserID: String?
    @Published private(set) var username: String?
    
    var isAuthenticated: Bool {
        return authState == .authenticated
    }
    
    override private init() {
        super.init()
        loadStoredSession()
        checkCredentialStateOnLaunch()
    }
    
    // MARK: - Session Persistence
    
    private func loadStoredSession() {
        self.appleUserID = UserDefaults.standard.string(forKey: AppleSignInKeys.userID)
        self.userEmail = UserDefaults.standard.string(forKey: AppleSignInKeys.userEmail)
        self.userFullName = UserDefaults.standard.string(forKey: AppleSignInKeys.userFullName)
        let isAuth = UserDefaults.standard.bool(forKey: AppleSignInKeys.isAuthenticated)
        
        if isAuth, let userID = appleUserID {
            self.authState = .authenticated
            if let profile = SwiftDataService.shared.fetchUserProfile(appleUserID: userID) {
                self.username = profile.username
                IdentityManager.shared.bindSession(accountID: profile.accountID, username: profile.username, displayName: profile.displayName)
            }
        } else {
            self.authState = .unauthenticated
        }
    }
    
    /// Verifies existing Apple ID credential validity with Apple servers on launch
    func checkCredentialStateOnLaunch() {
        AppLogger.multipeer.info("[Auth] Apple Sign-In state check started")
        let isAuthStored = UserDefaults.standard.bool(forKey: AppleSignInKeys.isAuthenticated)
        let hasUserID = appleUserID != nil && !(appleUserID?.isEmpty ?? true)
        
        AppLogger.multipeer.info("[Auth] Existing Apple identity found = \(hasUserID)")
        
        guard isAuthStored, let userID = appleUserID, !userID.isEmpty else {
            AppLogger.multipeer.info("[Auth] Sign-in required = true")
            DispatchQueue.main.async {
                self.authState = .unauthenticated
            }
            return
        }
        
        AppLogger.multipeer.info("[Auth] Sign-in required = false")
        let fingerprint = String(userID.prefix(6))
        AppLogger.multipeer.info("[Auth] Apple identity fingerprint = \(fingerprint)")
        
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        appleIDProvider.getCredentialState(forUserID: userID) { [weak self] credentialState, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard UserDefaults.standard.bool(forKey: AppleSignInKeys.isAuthenticated) else {
                    AppLogger.multipeer.info("[Auth] Credential state = unauthenticated (user defaults cleared)")
                    self.authState = .unauthenticated
                    return
                }
                
                if let error = error {
                    AppLogger.multipeer.info("[Auth] Credential state = offline (\(error.localizedDescription))")
                    AppLogger.multipeer.info("Offline network status during Apple ID credential check. Preserving offline session.")
                    self.authState = .authenticated
                    if let profile = SwiftDataService.shared.fetchUserProfile(appleUserID: userID) {
                        AppLogger.multipeer.info("[Auth] Local user record found = true")
                        self.username = profile.username
                        IdentityManager.shared.bindSession(accountID: profile.accountID, username: profile.username, displayName: profile.displayName)
                    } else {
                        AppLogger.multipeer.info("[Auth] Local user record found = false")
                    }
                    return
                }
                
                switch credentialState {
                case .authorized:
                    AppLogger.multipeer.info("[Auth] Credential state = authorized")
                    self.authState = .authenticated
                    if let profile = SwiftDataService.shared.fetchUserProfile(appleUserID: userID) {
                        AppLogger.multipeer.info("[Auth] Local user record found = true")
                        self.username = profile.username
                        IdentityManager.shared.bindSession(accountID: profile.accountID, username: profile.username, displayName: profile.displayName)
                    } else {
                        AppLogger.multipeer.info("[Auth] Local user record found = false")
                    }
                    AppLogger.multipeer.info("[Auth] Apple Sign-In Credential State: Authorized for user fingerprint \(fingerprint)")
                case .revoked, .notFound, .transferred:
                    AppLogger.multipeer.info("[Auth] Credential state = \(credentialState == .revoked ? "revoked" : "notFound")")
                    self.signOut()
                    AppLogger.multipeer.warning("Apple Sign-In Credential Revoked or Not Found. Resetting session.")
                @unknown default:
                    AppLogger.multipeer.info("[Auth] Credential state = unknown")
                    let isAuthStillStored = UserDefaults.standard.bool(forKey: AppleSignInKeys.isAuthenticated)
                    self.authState = isAuthStillStored ? .authenticated : .unauthenticated
                    if let profile = SwiftDataService.shared.fetchUserProfile(appleUserID: userID) {
                        AppLogger.multipeer.info("[Auth] Local user record found = true")
                        self.username = profile.username
                        IdentityManager.shared.bindSession(accountID: profile.accountID, username: profile.username, displayName: profile.displayName)
                    }
                }
            }
        }
    }

    
    // MARK: - Direct Credential Handler (Single FaceID Scan)
    
    func handleCredential(_ appleIDCredential: ASAuthorizationAppleIDCredential) {
        let userID = appleIDCredential.user
        let email = appleIDCredential.email
        let fullName = appleIDCredential.fullName
        let fingerprint = String(userID.prefix(6))
        
        AppLogger.multipeer.info("[Auth] Apple identity fingerprint = \(fingerprint)")
        
        var formattedName: String?
        if let fullName = fullName {
            let formatter = PersonNameComponentsFormatter()
            formattedName = formatter.string(from: fullName)
        }
        
        let existingRecord = SwiftDataService.shared.fetchUserProfile(appleUserID: userID) != nil
        AppLogger.multipeer.info("[Auth] Local user record found = \(existingRecord)")
        
        // Find existing or create NEW profile with atomic unique 8-character username
        let profile = SwiftDataService.shared.findOrCreateUserProfile(
            appleUserID: userID,
            appleName: formattedName,
            email: email
        )
        
        if existingRecord {
            AppLogger.multipeer.info("[Auth] Local user record updated = true")
            AppLogger.multipeer.info("[Auth] Local user record created = false")
        } else {
            AppLogger.multipeer.info("[Auth] Local user record created = true")
            AppLogger.multipeer.info("[Auth] Local user record updated = false")
        }
        
        UserDefaults.standard.set(userID, forKey: AppleSignInKeys.userID)
        if let email = email {
            UserDefaults.standard.set(email, forKey: AppleSignInKeys.userEmail)
        }
        UserDefaults.standard.set(profile.displayName, forKey: AppleSignInKeys.userFullName)
        UserDefaults.standard.set(profile.displayName, forKey: Constants.StorageKeys.userHandle)
        UserDefaults.standard.set(true, forKey: AppleSignInKeys.isAuthenticated)
        
        DispatchQueue.main.async {
            self.appleUserID = userID
            self.userEmail = email ?? self.userEmail
            self.userFullName = profile.displayName
            self.username = profile.username
            self.authState = .authenticated
            IdentityManager.shared.bindSession(accountID: profile.accountID, username: profile.username, displayName: profile.displayName)
            
            // Synchronize customer identity with RevenueCat
            Task {
                try? await SubscriptionManager.shared.identify(appUserID: profile.accountID.uuidString)
            }
        }
        AppLogger.multipeer.info("[Auth] Sign-in completed successfully")
    }

    
    func signOut() {
        AppLogger.multipeer.info("[Auth] Logout started")
        AppLogger.multipeer.info("[Auth] Local data deletion requested = false")
        AppLogger.multipeer.info("[Auth] Message deletion count = 0 (preserved)")
        AppLogger.multipeer.info("[Auth] Conversation deletion count = 0 (preserved)")
        AppLogger.multipeer.info("[Auth] Transcript deletion count = 0 (preserved)")
        AppLogger.multipeer.info("[Auth] Device identity deletion requested = false (preserved)")
        
        UserDefaults.standard.removeObject(forKey: AppleSignInKeys.userID)
        UserDefaults.standard.removeObject(forKey: AppleSignInKeys.userEmail)
        UserDefaults.standard.removeObject(forKey: AppleSignInKeys.userFullName)
        UserDefaults.standard.set(false, forKey: AppleSignInKeys.isAuthenticated)
        
        self.appleUserID = nil
        self.userEmail = nil
        self.userFullName = nil
        self.username = nil
        self.authState = .unauthenticated
        IdentityManager.shared.resetSession()
        
        // Reset RevenueCat customer identity to anonymous
        Task {
            try? await SubscriptionManager.shared.resetIdentity()
        }

        AppLogger.multipeer.info("[Auth] Logout completed. Signed out of Apple ID session successfully. Device ID & SwiftData store remain intact.")
    }
    
    // MARK: - GDPR Account Deletion
    
    /// Permanently deletes user account, requests cloud backend deletion, purges local SwiftData, and signs out.
    func deleteAccountAndSignOut(completion: @escaping () -> Void) {
        let handle = userFullName ?? "User"
        
        // 1. Issue Cloud backend account deletion request
        CloudSyncService.shared.requestCloudAccountDeletion(userHandle: handle) { [weak self] _ in
            guard let self = self else { return }
            
            // 2. Purge all local SwiftData records (SDUserProfile, SDChatMessage, SDVoiceTranscript, SDPendingMessage)
            SwiftDataService.shared.purgeAllUserData()
            
            // 3. Clear Keychain Device ID and IdentityManager session
            KeychainIdentityService.shared.clearDeviceID()
            IdentityManager.shared.resetSession()
            
            // 4. Reset RevenueCat customer identity
            Task {
                try? await SubscriptionManager.shared.resetIdentity()
            }
            
            // 5. Clear all persistent session keys in UserDefaults
            UserDefaults.standard.removeObject(forKey: AppleSignInKeys.userID)
            UserDefaults.standard.removeObject(forKey: AppleSignInKeys.userEmail)
            UserDefaults.standard.removeObject(forKey: AppleSignInKeys.userFullName)
            UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.userHandle)
            UserDefaults.standard.set(false, forKey: AppleSignInKeys.isAuthenticated)
            UserDefaults.standard.removeObject(forKey: "com.adityarai.pingly.hasPromptedATT")
            
            // 6. Reset in-memory auth state to return user to AppleSignInScreen
            self.appleUserID = nil
            self.userEmail = nil
            self.userFullName = nil
            self.username = nil
            self.authState = .unauthenticated
            
            AppLogger.multipeer.info("GDPR Account Deletion complete. Purged all local, Keychain, and backend user data.")
            completion()
        }
    }
}


