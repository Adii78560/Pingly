//
//  KeychainIdentityService.swift
//  Relayn
//
//  Created by Senior iOS Developer on 13/08/26.
//

import Foundation
import Security
import os

/// Dedicated secure Keychain storage manager for Relayn Device ID persistence across app reinstalls
final class KeychainIdentityService {
    static let shared = KeychainIdentityService()
    
    private let primaryDeviceIDKey = "com.RaiEnterprise.Pingly.deviceIdentity"
    private let legacyDeviceIDKey = "com.adityarai.pingly.deviceID"
    private let serviceName = "com.adityarai.pingly.keychain"
    
    private let lock = NSLock()
    private var cachedDeviceID: UUID? = nil
    
    private init() {}
    
    /// Fetches existing Device ID from iOS Keychain (or memory cache), or generates & saves a new UUID if absent.
    func fetchOrCreateDeviceID() -> UUID {
        lock.lock()
        if let cached = cachedDeviceID {
            lock.unlock()
            return cached
        }
        
        // Ensure thread-safe single initialization
        AppLogger.general.info("[Identity] Device identity initialization started")
        AppLogger.general.info("[Identity] Keychain lookup started")
        
        var existingFound = false
        var loadedUUID: UUID? = nil
        
        // 1. Primary Keychain Key lookup
        if let primaryString = readKeychainItem(key: primaryDeviceIDKey),
           let uuid = UUID(uuidString: primaryString) {
            existingFound = true
            loadedUUID = uuid
        } 
        // 2. Legacy Keychain Key fallback lookup
        else if let legacyString = readKeychainItem(key: legacyDeviceIDKey),
                let uuid = UUID(uuidString: legacyString) {
            existingFound = true
            loadedUUID = uuid
            // Migrate to primary key for future continuity
            saveKeychainItem(key: primaryDeviceIDKey, value: uuid.uuidString)
            AppLogger.general.info("[Identity] Migrated legacy Keychain Device ID to primary key.")
        }
        
        let finalUUID: UUID
        if existingFound, let uuid = loadedUUID {
            let fingerprint = String(uuid.uuidString.prefix(6))
            AppLogger.general.info("[Identity] Existing device identity found = true")
            AppLogger.general.info("[Identity] Device identity loaded successfully")
            AppLogger.general.info("[Identity] Device identity generated = false")
            AppLogger.general.info("[Identity] Device identity persisted = true")
            AppLogger.general.info("[Identity] Device ID fingerprint = \(fingerprint)")
            AppLogger.general.info("[Identity] Device identity initialization completed")
            finalUUID = uuid
        } else {
            // 3. Generate NEW UUID if no existing identity found in Keychain
            let newUUID = UUID()
            saveKeychainItem(key: primaryDeviceIDKey, value: newUUID.uuidString)
            let fingerprint = String(newUUID.uuidString.prefix(6))
            
            AppLogger.general.info("[Identity] Existing device identity found = false")
            AppLogger.general.info("[Identity] Device identity generated = true")
            AppLogger.general.info("[Identity] Device identity persisted = true")
            AppLogger.general.info("[Identity] Device ID fingerprint = \(fingerprint)")
            AppLogger.general.info("[Identity] Device identity initialization completed")
            finalUUID = newUUID
        }
        
        cachedDeviceID = finalUUID
        lock.unlock()
        return finalUUID
    }
    
    /// Permanently deletes Device ID from iOS Keychain (strictly during explicit account deletion)
    func clearDeviceID() {
        lock.lock()
        cachedDeviceID = nil
        lock.unlock()
        
        deleteKeychainItem(key: primaryDeviceIDKey)
        deleteKeychainItem(key: legacyDeviceIDKey)
        AppLogger.general.info("Cleared Relayn Device ID from iOS Keychain.")
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
