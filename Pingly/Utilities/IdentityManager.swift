//
//  IdentityManager.swift
//  Pingly
//
//  Created by Senior iOS Developer on 13/08/26.
//

import Foundation
import Combine

/// Central coordinator enforcing the separation of Pingly Account ID, Device ID, and Display Name
@MainActor
final class IdentityManager: ObservableObject {
    static let shared = IdentityManager()
    
    @Published private(set) var accountID: UUID?
    @Published private(set) var deviceID: UUID
    @Published private(set) var displayName: String
    @Published private(set) var username: String?
    
    private init() {
        // Device ID is loaded from iOS Keychain
        self.deviceID = KeychainIdentityService.shared.fetchOrCreateDeviceID()
        self.displayName = UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
    }
    
    /// Binds active Apple user session to a stable Pingly Account ID
    func bindSession(accountID: UUID, username: String, displayName: String) {
        self.accountID = accountID
        self.username = username
        self.displayName = displayName
        
        UserDefaults.standard.set(displayName, forKey: Constants.StorageKeys.userHandle)
        UserDefaults.standard.set(accountID.uuidString, forKey: "com.adityarai.pingly.accountID")
    }
    
    /// Updates user's mutable Display Name without altering Account ID, Device ID, or Username
    func updateDisplayName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        self.displayName = trimmed
        UserDefaults.standard.set(trimmed, forKey: Constants.StorageKeys.userHandle)
        
        // Update SwiftData profile record if authenticated
        if let appleID = AppleSignInManager.shared.appleUserID,
           let profile = SwiftDataService.shared.fetchUserProfile(appleUserID: appleID) {
            profile.displayName = trimmed
            profile.updatedAt = Date()
        }
    }
    
    /// Clears runtime session identity upon logout or account deletion
    func resetSession() {
        self.accountID = nil
        self.username = nil
    }
    
    /// Debug summary for verification during development
    var debugIdentitySummary: String {
        return """
        Account ID: \(accountID?.uuidString ?? "Unauthenticated")
        Device ID: \(deviceID.uuidString)
        Username: \(username ?? "None")
        Display Name: \(displayName)
        """
    }
}
