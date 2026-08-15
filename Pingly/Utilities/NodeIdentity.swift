//
//  NodeIdentity.swift
//  Relayn
//
//  Created by Senior iOS Developer on 13/08/26.
//

import Foundation

/// Persistent stable device & node identity manager delegating to KeychainIdentityService and IdentityManager
final class NodeIdentity {
    static let shared = NodeIdentity()
    
    private init() {}
    
    /// Stable Device ID derived from Keychain
    var nodeID: String {
        return KeychainIdentityService.shared.fetchOrCreateDeviceID().uuidString
    }
    
    /// User display handle (mutable profile information)
    var displayName: String {
        return UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
    }
}
