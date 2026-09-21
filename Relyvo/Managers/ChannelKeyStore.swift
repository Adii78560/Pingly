import Foundation
import CryptoKit
import Security
import os

public final class ChannelKeyStore {
    public static let shared = ChannelKeyStore()
    
    private var inMemoryKeys: [String: SymmetricKey] = [:]
    private let queue = DispatchQueue(label: "com.RaiEnterprise.Relyvo.ChannelKeyStore", attributes: .concurrent)
    
    private init() {}
    
    /// Loads the key from the keychain or in-memory cache.
    public func key(for channelID: String) -> SymmetricKey? {
        let upperChannel = channelID.uppercased()
        
        var cachedKey: SymmetricKey?
        queue.sync {
            cachedKey = inMemoryKeys[upperChannel]
        }
        if let key = cachedKey { return key }
        
        if let keyData = loadFromKeychain(channelID: upperChannel) {
            let key = SymmetricKey(data: keyData)
            queue.async(flags: .barrier) {
                self.inMemoryKeys[upperChannel] = key
            }
            return key
        }
        
        return nil
    }
    
    /// Returns true if a key exists for the given channel.
    public func hasKey(for channelID: String) -> Bool {
        return key(for: channelID) != nil
    }
    
    /// Derives and sets a new key for the given channel. Optionally persists it to Keychain.
    public func setKey(passphrase: String, for channelID: String, persistInKeychain: Bool = true) -> Bool {
        let upperChannel = channelID.uppercased()
        guard let derivedKey = ChannelCrypto.deriveKey(passphrase: passphrase, channelID: upperChannel) else { return false }
        
        queue.async(flags: .barrier) {
            self.inMemoryKeys[upperChannel] = derivedKey
        }
        
        if persistInKeychain {
            let keyData = derivedKey.withUnsafeBytes { Data($0) }
            saveToKeychain(channelID: upperChannel, keyData: keyData)
        }
        return true
    }
    
    /// Directly imports a shared key (e.g., from QR code) and persists it.
    public func importKey(key: SymmetricKey, for channelID: String, persistInKeychain: Bool = true) {
        let upperChannel = channelID.uppercased()
        
        queue.async(flags: .barrier) {
            self.inMemoryKeys[upperChannel] = key
        }
        
        if persistInKeychain {
            let keyData = key.withUnsafeBytes { Data($0) }
            saveToKeychain(channelID: upperChannel, keyData: keyData)
        }
    }
    
    /// Removes the key from memory and Keychain.
    public func lockChannel(channelID: String) {
        let upperChannel = channelID.uppercased()
        queue.async(flags: .barrier) {
            self.inMemoryKeys.removeValue(forKey: upperChannel)
        }
        deleteFromKeychain(channelID: upperChannel)
    }
    
    public func clearAllKeys() {
        queue.async(flags: .barrier) {
            self.inMemoryKeys.removeAll()
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.RaiEnterprise.Relyvo.channelKeys"
        ]
        SecItemDelete(query as CFDictionary)
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .didPurgeChannelKeys, object: nil)
        }
    }
    
    // MARK: - Keychain Helpers
    
    private func keychainQuery(channelID: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.RaiEnterprise.Relyvo.channelKeys",
            kSecAttrAccount as String: "relyvo.channel.\(channelID)"
        ]
    }
    
    private func saveToKeychain(channelID: String, keyData: Data) {
        var query = keychainQuery(channelID: channelID)
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        
        SecItemDelete(keychainQuery(channelID: channelID) as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func loadFromKeychain(channelID: String) -> Data? {
        var query = keychainQuery(channelID: channelID)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess {
            return dataTypeRef as? Data
        }
        return nil
    }
    
    private func deleteFromKeychain(channelID: String) {
        let query = keychainQuery(channelID: channelID)
        SecItemDelete(query as CFDictionary)
    }
}
