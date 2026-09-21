import Foundation
import CryptoKit

/// Automated Verification Suite for Custom Channel Cryptographic Isolation
final class CryptoIsolationTests {
    
    static let shared = CryptoIsolationTests()
    
    private init() {}
    
    func runAllCryptoTests() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        
        let tests = [
            ("testHKDFKeyDerivation", testHKDFKeyDerivation),
            ("testAESGCMEncryptionRoundtrip", testAESGCMEncryptionRoundtrip),
            ("testTamperedCiphertextRejection", testTamperedCiphertextRejection),
            ("testMeshPacketHeaderEncryptionFlag", testMeshPacketHeaderEncryptionFlag),
            ("testQRURLSchemeParsing", testQRURLSchemeParsing)
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
    
    private func testHKDFKeyDerivation() -> Bool {
        guard let key1 = ChannelCrypto.deriveKey(passphrase: "secret", channelID: "CH-SECURE") else { return false }
        guard let key2 = ChannelCrypto.deriveKey(passphrase: "secret", channelID: "CH-SECURE") else { return false }
        let key3 = ChannelCrypto.deriveKey(passphrase: "wrong", channelID: "CH-SECURE")
        
        let data1 = key1.withUnsafeBytes { Data($0) }
        let data2 = key2.withUnsafeBytes { Data($0) }
        let data3 = key3?.withUnsafeBytes { Data($0) }
        
        return data1 == data2 && data1 != data3
    }
    
    private func testAESGCMEncryptionRoundtrip() -> Bool {
        guard let key = ChannelCrypto.deriveKey(passphrase: "test", channelID: "CH-TEST") else { return false }
        let payload = "Hello Secure Mesh".data(using: .utf8)!
        
        guard let sealed = ChannelCrypto.encrypt(data: payload, key: key) else { return false }
        
        do {
            let decrypted = try ChannelCrypto.decrypt(sealedData: sealed, key: key)
            return decrypted == payload
        } catch {
            return false
        }
    }
    
    private func testTamperedCiphertextRejection() -> Bool {
        guard let key = ChannelCrypto.deriveKey(passphrase: "test", channelID: "CH-TEST") else { return false }
        let payload = "Hello Secure Mesh".data(using: .utf8)!
        
        guard var sealed = ChannelCrypto.encrypt(data: payload, key: key) else { return false }
        
        // Tamper with the ciphertext (flip a byte)
        sealed[15] = sealed[15] ^ 0xFF
        
        do {
            _ = try ChannelCrypto.decrypt(sealedData: sealed, key: key)
            return false // Should have thrown
        } catch {
            return true // Successfully rejected
        }
    }
    
    private func testMeshPacketHeaderEncryptionFlag() -> Bool {
        let msg = Message(
            senderID: "A",
            senderName: "Alice",
            channelID: "CH-SECURE",
            text: "EncryptedDataInBase64",
            isEncrypted: true
        )
        
        do {
            // Encode the message, treating `text` as raw ciphertext string representation
            let ciphertext = Data(base64Encoded: "EncryptedDataInBase64")!
            let encoded = try MeshPacketHeader.encode(msg, sequenceNumber: 1, isEncrypted: true, encryptedPayload: ciphertext)
            
            // Decode the message
            let decodedHeader = try MeshPacketHeader.decode(from: encoded)
            
            // Verify flag and payload
            return decodedHeader.flags.isEncrypted && decodedHeader.textPayload == "EncryptedDataInBase64"
        } catch {
            return false
        }
    }
    
    private func testQRURLSchemeParsing() -> Bool {
        let channelID = "CH-QR-TEST"
        let key = ChannelCrypto.deriveKey(passphrase: "secret", channelID: channelID)!
        let keyBase64 = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        
        var components = URLComponents()
        components.scheme = "relyvo"
        components.host = "channel"
        components.path = "/v1"
        components.queryItems = [
            URLQueryItem(name: "id", value: channelID),
            URLQueryItem(name: "key", value: keyBase64)
        ]
        
        guard let urlString = components.url?.absoluteString else { return false }
        
        // Simulating the decoding from QRScannerView
        guard let parsedComponents = URLComponents(string: urlString),
              parsedComponents.scheme == "relyvo",
              parsedComponents.host == "channel",
              let queryItems = parsedComponents.queryItems,
              let parsedID = queryItems.first(where: { $0.name == "id" })?.value,
              let parsedKeyBase64 = queryItems.first(where: { $0.name == "key" })?.value else {
            return false
        }
        
        return parsedID == channelID && parsedKeyBase64 == keyBase64
    }
}
