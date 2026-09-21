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
        let isAuthStored = UserDefaults.standard.bool(forKey: AppleSignInKeys.isAuthenticated)
        _ = appleUserID != nil && !(appleUserID?.isEmpty ?? true)
        
        
        guard isAuthStored, let userID = appleUserID, !userID.isEmpty else {
            DispatchQueue.main.async {
                self.authState = .unauthenticated
            }
            return
        }
        
        _ = String(userID.prefix(6))
        
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        appleIDProvider.getCredentialState(forUserID: userID) { [weak self] credentialState, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard UserDefaults.standard.bool(forKey: AppleSignInKeys.isAuthenticated) else {
                    self.authState = .unauthenticated
                    return
                }
                
                if error != nil {
                    AppLogger.multipeer.info("Offline network status during Apple ID credential check. Preserving offline session.")
                    self.authState = .authenticated
                    if let profile = SwiftDataService.shared.fetchUserProfile(appleUserID: userID) {
                        self.username = profile.username
                        IdentityManager.shared.bindSession(accountID: profile.accountID, username: profile.username, displayName: profile.displayName)
                    } else {
                    }
                    return
                }
                
                switch credentialState {
                case .authorized:
                    self.authState = .authenticated
                    if let profile = SwiftDataService.shared.fetchUserProfile(appleUserID: userID) {
                        self.username = profile.username
                        IdentityManager.shared.bindSession(accountID: profile.accountID, username: profile.username, displayName: profile.displayName)
                    } else {
                    }
                case .revoked, .notFound, .transferred:
                    self.signOut()
                    AppLogger.multipeer.warning("Apple Sign-In Credential Revoked or Not Found. Resetting session.")
                @unknown default:
                    let isAuthStillStored = UserDefaults.standard.bool(forKey: AppleSignInKeys.isAuthenticated)
                    self.authState = isAuthStillStored ? .authenticated : .unauthenticated
                    if let profile = SwiftDataService.shared.fetchUserProfile(appleUserID: userID) {
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
        _ = String(userID.prefix(6))
        
        
        var formattedName: String?
        if let fullName = fullName {
            let formatter = PersonNameComponentsFormatter()
            formattedName = formatter.string(from: fullName)
        }
        
        let existingRecord = SwiftDataService.shared.fetchUserProfile(appleUserID: userID) != nil
        
        // Find existing or create NEW profile with atomic unique 8-character username
        let profile = SwiftDataService.shared.findOrCreateUserProfile(
            appleUserID: userID,
            appleName: formattedName,
            email: email
        )
        
        if existingRecord {
        } else {
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
    }

    
    func signOut() {
        
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
            
            // 3. Clear Keychain Device ID, Channel Keys, and IdentityManager session
            KeychainIdentityService.shared.clearDeviceID()
            ChannelKeyStore.shared.clearAllKeys()
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


