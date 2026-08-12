//
//  NodeIdentity.swift
//  Pingly
//
//  Created by Senior iOS Developer on 12/08/26.
//

import Foundation

/// Persistent stable device & node identity manager for Pingly Mesh V2
final class NodeIdentity {
    static let shared = NodeIdentity()
    
    private let nodeIDKey = "com.RaiEnterprise.Pingly.stableNodeID"
    private(set) var nodeID: String
    
    private init() {
        if let existingID = UserDefaults.standard.string(forKey: nodeIDKey), !existingID.isEmpty {
            self.nodeID = existingID
        } else {
            let newID = "NODE-\(UUID().uuidString.prefix(8).uppercased())"
            UserDefaults.standard.set(newID, forKey: nodeIDKey)
            self.nodeID = newID
        }
    }
    
    /// User display handle (non-routing)
    var displayName: String {
        return UserDefaults.standard.string(forKey: Constants.StorageKeys.userHandle) ?? Constants.App.defaultUserHandle
    }
    
    /// Reset node ID (strictly for test harness isolation)
    func resetForTesting() {
        let newID = "NODE-\(UUID().uuidString.prefix(8).uppercased())"
        UserDefaults.standard.set(newID, forKey: nodeIDKey)
        self.nodeID = newID
    }
}
