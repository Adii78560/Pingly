//
//  KeychainIdentityService.swift
//  Pingly
//
//  Created by Senior iOS Developer on 13/08/26.
//

import Foundation
import Security
import os

/// Dedicated secure Keychain storage manager for Pingly Device ID persistence across app reinstalls
final class KeychainIdentityService {
    static let shared = KeychainIdentityService()
    
    private let deviceIDKey = "com.adityarai.pingly.deviceID"
    private let serviceName = "com.adityarai.pingly.keychain"
    
    private init() {}
    
    /// Fetches existing Device ID from iOS Keychain, or generates & saves a new UUID if absent.
    func fetchOrCreateDeviceID() -> UUID {
        if let existingUUIDString = readKeychainItem(key: deviceIDKey),
           let uuid = UUID(uuidString: existingUUIDString) {
            return uuid
        }
        
        let newUUID = UUID()
        saveKeychainItem(key: deviceIDKey, value: newUUID.uuidString)
        AppLogger.general.info("Generated NEW Pingly Device ID and stored securely in iOS Keychain.")
        return newUUID
    }
    
    /// Permanently deletes Device ID from iOS Keychain (strictly during explicit account deletion)
    func clearDeviceID() {
        deleteKeychainItem(key: deviceIDKey)
        AppLogger.general.info("Cleared Pingly Device ID from iOS Keychain.")
    }
    
    // MARK: - Private Apple Security Keychain Helpers
    
    private func readKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        guard status == errSecSuccess, let data = dataTypeRef as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    private func saveKeychainItem(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        
        // Delete any existing item first
        deleteKeychainItem(key: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.general.error("Failed to save Keychain item for key '\(key)': status \(status)")
        }
    }
    
    private func deleteKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
