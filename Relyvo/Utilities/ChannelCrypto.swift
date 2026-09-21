import Foundation
import CryptoKit

public struct ChannelCrypto {
    
    /// Derives a 256-bit symmetric key using HKDF-SHA256 from a passphrase and channel ID.
    public static func deriveKey(passphrase: String, channelID: String) -> SymmetricKey? {
        guard let ikm = passphrase.data(using: .utf8),
              let salt = channelID.uppercased().data(using: .utf8),
              let info = "RelyvoChannelEncryption".data(using: .utf8) else {
            return nil
        }
        
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }
    
    /// Encrypts binary data using AES-GCM-256 and appends the 12-byte Nonce and 16-byte Auth Tag.
    /// Format: [12-byte Nonce] + [Ciphertext] + [16-byte Tag]
    public static func encrypt(data: Data, key: SymmetricKey) -> Data? {
        do {
            let nonce = try AES.GCM.Nonce(data: Data(count: 12).map { _ in UInt8.random(in: 0...255) })
            let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
            
            var combined = Data()
            combined.append(contentsOf: nonce)
            combined.append(sealedBox.ciphertext)
            combined.append(sealedBox.tag)
            
            return combined
        } catch {
            return nil
        }
    }
    
    /// Decrypts binary data encrypted by `encrypt(data:key:)`.
    public static func decrypt(sealedData: Data, key: SymmetricKey) throws -> Data {
        guard sealedData.count > 28 else {
            throw CryptoError.payloadTooShort
        }
        
        let nonceData = sealedData.prefix(12)
        let tagData = sealedData.suffix(16)
        let ciphertext = sealedData.dropFirst(12).dropLast(16)
        
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData)
        
        return try AES.GCM.open(sealedBox, using: key)
    }
    
    /// Computes a truncated HMAC-SHA256 for CHANNEL_PING privacy masking.
    public static func computeChannelPingHash(channelID: String, key: SymmetricKey) -> Data? {
        guard let data = channelID.uppercased().data(using: .utf8) else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(mac).prefix(4)
    }
    
    enum CryptoError: Error {
        case payloadTooShort
    }
}
