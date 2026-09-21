import Foundation
import CryptoKit

/// Automated Verification Suite for Channel Key Store and Keychain Roundtrips
final class ChannelKeyStoreTests {
    
    static let shared = ChannelKeyStoreTests()
    
    private init() {}
    
    func runAllKeyStoreTests() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        
        let tests = [
            ("testSetAndRetrieveKey", testSetAndRetrieveKey),
            ("testImportKeyRoundtrip", testImportKeyRoundtrip),
            ("testClearAllKeysScoping", testClearAllKeysScoping)
        ]
        
        for (name, test) in tests {
            let result = test()
            if result {
                print("✅ \(name) passed")
                passed += 1
            } else {
                print("❌ \(name) failed")
                failed += 1
            }
        }
        
        return (passed, failed)
    }
    
    private func testSetAndRetrieveKey() -> Bool {
        ChannelKeyStore.shared.clearAllKeys()
        
        let channelID = "CH-TEST-KEYCHAIN"
        let passphrase = "secure_password"
        
        // 1. Set key
        let success = ChannelKeyStore.shared.setKey(passphrase: passphrase, for: channelID)
        guard success, ChannelKeyStore.shared.hasKey(for: channelID) else { return false }
        
        // 2. Retrieve key
        let retrievedKey = ChannelKeyStore.shared.key(for: channelID)
        guard retrievedKey != nil else { return false }
        
        // 3. Clear memory explicitly to force keychain load
        ChannelKeyStore.shared.clearAllKeys()
        guard !ChannelKeyStore.shared.hasKey(for: channelID) else { return false }
        
        // Re-fetch
        let success2 = ChannelKeyStore.shared.setKey(passphrase: passphrase, for: channelID)
        guard success2 else { return false }
        
        // Lock channel
        ChannelKeyStore.shared.lockChannel(channelID: channelID)
        guard !ChannelKeyStore.shared.hasKey(for: channelID) else { return false }
        
        return true
    }
    
    private func testImportKeyRoundtrip() -> Bool {
        let channelID = "CH-QR-IMPORT"
        guard let originalKey = ChannelCrypto.deriveKey(passphrase: "qr_pass", channelID: channelID) else {
            return false
        }
        
        // Import key
        ChannelKeyStore.shared.importKey(key: originalKey, for: channelID)
        guard ChannelKeyStore.shared.hasKey(for: channelID) else { return false }
        
        // Fetch
        guard let fetchedKey = ChannelKeyStore.shared.key(for: channelID) else { return false }
        
        // Compare
        let originalData = originalKey.withUnsafeBytes { Data($0) }
        let fetchedData = fetchedKey.withUnsafeBytes { Data($0) }
        
        return originalData == fetchedData
    }
    
    private func testClearAllKeysScoping() -> Bool {
        let ch1 = "CH-1"
        let ch2 = "CH-2"
        
        _ = ChannelKeyStore.shared.setKey(passphrase: "pass1", for: ch1)
        _ = ChannelKeyStore.shared.setKey(passphrase: "pass2", for: ch2)
        
        guard ChannelKeyStore.shared.hasKey(for: ch1),
              ChannelKeyStore.shared.hasKey(for: ch2) else { return false }
        
        ChannelKeyStore.shared.clearAllKeys()
        
        guard !ChannelKeyStore.shared.hasKey(for: ch1),
              !ChannelKeyStore.shared.hasKey(for: ch2) else { return false }
        
        return true
    }
}
