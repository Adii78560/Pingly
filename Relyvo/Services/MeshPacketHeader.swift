//
//  MeshPacketHeader.swift
//  Relyvo
//
//  Compact binary framing protocol for mesh text/control packets.
//  Replaces JSON serialization on the wire to reduce payload size by ~70-80%
//  compared to the JSON-encoded Message struct.
//
//  Wire format (62-byte fixed header + variable payload):
//
//  Offset  Size  Field
//  0-1     2     Magic bytes: 0x52 0x45 ("RE") — distinguishes from PTTFrameHeader (0x50 "P")
//  2       1     Protocol version (0x02)
//  3       1     Packet type (MeshPacketType raw value)
//  4       1     Channel byte (MeshChannelByte raw value; 0xFF = custom channel)
//  5       1     Hop count (UInt8)
//  6       1     TTL (UInt8)
//  7-22    16    Origin node UUID (raw uuid_t, big-endian byte order)
//  23-38   16    Destination UUID (raw uuid_t; all-zero bytes = BROADCAST)
//  39-54   16    Message ID UUID (raw uuid_t)
//  55-58   4     Payload length in bytes (UInt32, big-endian)
//  59      1     Flags byte (bit0=isSOS, bit1=isChannelBroadcast, bit2=isRelayHop)
//  60-61   2     Reserved (0x00 0x00)
//  ------
//  62 bytes total fixed header
//
//  Payload immediately follows the header as raw bytes:
//    • TEXT / TRANSCRIPT / ACK: UTF-8 encoded text string
//    • LOCATION: UTF-8 JSON-encoded location sub-payload
//    • CHANNEL_PING: empty (0 bytes)
//

import Foundation

// MARK: - Packet Type Discriminator

/// 1-byte packet type field carried in MeshPacketHeader.
enum MeshPacketType: UInt8 {
    case pttAudioChunk  = 0x01   // PTT audio voice chunk (handled by PTTFrameHeader; reserved here)
    case floorControl   = 0x02   // PTT floor request / release control signal
    case channelPing    = 0x03   // Heartbeat / channel presence ping
    case text           = 0x04   // Chat or transcript text payload
    case ack            = 0x05   // Delivery acknowledgement
    case location       = 0x06   // Location sharing payload
    
    /// Maps from the semantic P2PMessageType used by the Message model.
    static func from(_ type: P2PMessageType) -> MeshPacketType {
        switch type {
        case .chat:                    return .text
        case .transcript:              return .text
        case .ack:                     return .ack
        case .location:                return .location
        case .locationRequest:         return .location
        case .locationResponse:        return .location
        case .locationSharingStarted:  return .location
        case .locationSharingStopped:  return .location
        case .locationExpired:         return .location
        case .relativePosition:        return .location
        case .channelSync:             return .channelPing
        }
    }
    
    /// Maps back to a P2PMessageType for local delivery after decode.
    func toP2PMessageType() -> P2PMessageType {
        switch self {
        case .pttAudioChunk:  return .transcript
        case .floorControl:   return .transcript
        case .channelPing:    return .channelSync
        case .text:           return .chat
        case .ack:            return .ack
        case .location:       return .location
        }
    }
}

// MARK: - Channel Byte Mapping

/// 1-byte channel identifier replacing the "CH-1 EMERGENCY" etc. 36-char strings on the wire.
enum MeshChannelByte: UInt8 {
    case ch1Emergency  = 0x01   // "CH-1 EMERGENCY"
    case ch2RescueMesh = 0x02   // "CH-2 RESCUE MESH"
    case ch3MountainOps = 0x03  // "CH-3 MOUNTAIN OPS"
    case ch4GeneralP2P = 0x04   // "CH-4 GENERAL P2P"
    case direct        = 0xFE   // Direct unicast (no channel)
    case custom        = 0xFF   // Custom channel — channel name is prepended to payload as length-prefixed string
    
    /// Encode a channel string to its single-byte representation.
    static func from(channelID: String?) -> MeshChannelByte {
        switch channelID?.uppercased() {
        case "CH-1 EMERGENCY":   return .ch1Emergency
        case "CH-2 RESCUE MESH": return .ch2RescueMesh
        case "CH-3 MOUNTAIN OPS": return .ch3MountainOps
        case "CH-4 GENERAL P2P": return .ch4GeneralP2P
        case nil:                return .direct
        default:                 return .custom
        }
    }
    
    /// Decode back to the canonical channel ID string.
    func toChannelIDString() -> String? {
        switch self {
        case .ch1Emergency:   return "CH-1 EMERGENCY"
        case .ch2RescueMesh:  return "CH-2 RESCUE MESH"
        case .ch3MountainOps: return "CH-3 MOUNTAIN OPS"
        case .ch4GeneralP2P:  return "CH-4 GENERAL P2P"
        case .direct:         return nil
        case .custom:         return nil   // Decoded from payload prefix by MeshPacketHeader.decode
        }
    }
}

// MARK: - Header Flags

/// Bit-packed flags byte (offset 59 in the header).
struct MeshPacketFlags {
    var isSOS: Bool
    var isChannelBroadcast: Bool
    var isRelayHop: Bool
    var isEOT: Bool  // Bit 3: End of Transmission signal
    
    var rawValue: UInt8 {
        var v: UInt8 = 0
        if isSOS              { v |= 0x01 }
        if isChannelBroadcast { v |= 0x02 }
        if isRelayHop         { v |= 0x04 }
        if isEOT              { v |= 0x08 }
        return v
    }
    
    init(raw: UInt8) {
        isSOS              = (raw & 0x01) != 0
        isChannelBroadcast = (raw & 0x02) != 0
        isRelayHop         = (raw & 0x04) != 0
        isEOT              = (raw & 0x08) != 0
    }
    
    init(isSOS: Bool = false, isChannelBroadcast: Bool = false, isRelayHop: Bool = false, isEOT: Bool = false) {
        self.isSOS              = isSOS
        self.isChannelBroadcast = isChannelBroadcast
        self.isRelayHop         = isRelayHop
        self.isEOT              = isEOT
    }
}

// MARK: - Decode Error

enum MeshPacketDecodeError: Error, LocalizedError {
    case tooShort(got: Int, need: Int)
    case badMagicBytes(byte0: UInt8, byte1: UInt8)
    case unknownPacketType(UInt8)
    case payloadLengthMismatch(declared: Int, available: Int)
    case malformedCustomChannelPrefix
    case customChannelPrefixOverflow(got: Int, max: Int)
    case invalidUTF8Payload
    
    var errorDescription: String? {
        switch self {
        case .tooShort(let got, let need):
            return "[BINARY_DECODE_ERR] data too short: got \(got) bytes, need ≥ \(need)"
        case .badMagicBytes(let b0, let b1):
            return "[BINARY_DECODE_ERR] bad magic bytes: 0x\(String(b0, radix: 16)) 0x\(String(b1, radix: 16)), expected 0x52 0x45"
        case .unknownPacketType(let v):
            return "[BINARY_DECODE_ERR] unknown packet type: 0x\(String(v, radix: 16))"
        case .payloadLengthMismatch(let declared, let available):
            return "[BINARY_DECODE_ERR] payload length mismatch: declared \(declared) bytes but only \(available) available"
        case .malformedCustomChannelPrefix:
            return "[BINARY_DECODE_ERR] malformed custom channel length prefix in payload"
        case .customChannelPrefixOverflow(let got, let max):
            return "[BINARY_DECODE_ERR] reason=CUSTOM_CHANNEL_PREFIX_OVERFLOW length=\(got) max=\(max)"
        case .invalidUTF8Payload:
            return "[BINARY_DECODE_ERR] payload is not valid UTF-8"
        }
    }
}

// MARK: - Mesh Packet (decoded view)

/// Fully decoded mesh packet — the output of `MeshPacketHeader.decode(from:)`.
struct MeshPacket {
    let version: UInt8
    let type: MeshPacketType
    let channelByte: MeshChannelByte
    let channelID: String?        // nil for direct/broadcast; custom string for .custom
    let hopCount: UInt8
    let ttl: UInt8
    let originUUID: UUID
    let destinationUUID: UUID?    // nil means BROADCAST
    let messageID: UUID
    let conversationID: UUID?     // v3: conversationID
    let sequenceNumber: UInt16    // Monotonic packet sequence counter
    let flags: MeshPacketFlags
    let relayHistory: [UUID]      // v3: bounded relay traversal
    let textPayload: String       // UTF-8 decoded payload (empty for channelPing)
    
    // Convenience: raw wire size this packet represents
    var wireSize: Int { 
        if version >= 0x03 {
            return MeshPacketHeader.fixedHeaderSizeV3 + (relayHistory.count * 16) + textPayload.utf8.count
        } else {
            return MeshPacketHeader.fixedHeaderSizeV2 + textPayload.utf8.count
        }
    }
    
    static let broadcastUUID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
}

// MARK: - Binary Encoder / Decoder

enum MeshPacketHeader {
    
    static let magicByte0: UInt8 = 0x52   // 'R'
    static let magicByte1: UInt8 = 0x45   // 'E'
    static let fixedHeaderSizeV2: Int = 62
    static let fixedHeaderSizeV3: Int = 78
    static let maxCustomChannelPrefixBytes: Int = 32
    
    // MARK: Encode: Message → Data
    
    /// Encodes a `Message` model to compact binary wire format.
    ///
    /// Size comparison vs JSON:
    ///   JSON:   400-600 bytes typical (with UUIDs as 36-char strings, field names, quotes)
    ///   Binary: 62 bytes header + payload (payload = text.utf8.count, no field name overhead)
    ///
    /// Reduction: ~70-80% for short text messages, up to ~50% for longer transcript payloads.
    static func encode(_ message: Message, sequenceNumber: UInt16 = 0, isEOT: Bool = false, relayHistory: [UUID] = []) -> Data {
        let channelByte = MeshChannelByte.from(channelID: message.channelID)
        let isChannelBroadcast = message.channelID != nil && !message.channelID!.isEmpty
        let isRelayHop = message.hopsCount > 0
        let flags = MeshPacketFlags(
            isSOS: message.isSOS,
            isChannelBroadcast: isChannelBroadcast,
            isRelayHop: isRelayHop,
            isEOT: isEOT
        )
        
        // Build payload: for custom channels, prefix payload with 1-byte length + channel name UTF-8
        var payloadData = Data()
        if channelByte == .custom, let cid = message.channelID,
           let cidBytes = cid.data(using: .utf8), cidBytes.count <= maxCustomChannelPrefixBytes {
            var cidLen = UInt8(cidBytes.count)
            payloadData.append(&cidLen, count: 1)
            payloadData.append(cidBytes)
        }
        let textBytes = message.text.data(using: .utf8) ?? Data()
        payloadData.append(textBytes)
        
        let boundedHistory = Array(relayHistory.prefix(Int(Constants.Emergency.broadcastTTL)))
        let expectedTotalSize = fixedHeaderSizeV3 + (boundedHistory.count * 16) + payloadData.count
        var data = Data(capacity: expectedTotalSize)
        
        // Magic bytes (0..1)
        data.append(magicByte0)
        data.append(magicByte1)
        // Protocol version (2)
        data.append(0x03) // Force v3 for outgoing
        // Packet type (3)
        data.append(MeshPacketType.from(message.type).rawValue)
        // Channel byte (4)
        data.append(channelByte.rawValue)
        // Hop count & TTL (5..6)
        data.append(UInt8(min(message.hopsCount, 255)))
        data.append(UInt8(min(message.ttl, 255)))
        // Origin UUID (7..22)
        data.append(uuidToData(UUID(uuidString: message.originID) ?? UUID()))
        // Destination UUID (23..38)
        if message.destinationID == "BROADCAST" {
            data.append(Data(count: 16))
        } else {
            data.append(uuidToData(UUID(uuidString: message.destinationID) ?? UUID()))
        }
        // Message ID (39..54)
        data.append(uuidToData(message.id))
        // Conversation ID (55..70)
        data.append(uuidToData(message.conversationID))
        // Payload length (71..74)
        let payloadLen = UInt32(payloadData.count).bigEndian
        withUnsafeBytes(of: payloadLen) { data.append(contentsOf: $0) }
        // Flags byte (75)
        data.append(flags.rawValue)
        // Sequence counter (76..77)
        let seqBE = sequenceNumber.bigEndian
        withUnsafeBytes(of: seqBE) { data.append(contentsOf: $0) }
        // Relay history count (78)
        data.append(UInt8(boundedHistory.count))
        // Relay history UUIDs (79...)
        for nodeUUID in boundedHistory {
            data.append(uuidToData(nodeUUID))
        }
        
        // Payload
        data.append(payloadData)
        
        assert(data.count == expectedTotalSize,
               "MeshPacketHeader encode size mismatch: \(data.count) vs \(expectedTotalSize)")
        return data
    }
    
    // MARK: Decode: Data → MeshPacket
    
    /// Decodes compact binary wire format back to a `MeshPacket`.
    /// Throws `MeshPacketDecodeError` on any structural violation.
    static func decode(from data: Data) throws -> MeshPacket {
        guard data.count >= fixedHeaderSizeV2 else {
            throw MeshPacketDecodeError.tooShort(got: data.count, need: fixedHeaderSizeV2)
        }
        guard data[0] == magicByte0, data[1] == magicByte1 else {
            throw MeshPacketDecodeError.badMagicBytes(byte0: data[0], byte1: data[1])
        }
        
        let version = data[2]
        
        let typeRaw = data[3]
        guard let packetType = MeshPacketType(rawValue: typeRaw) else {
            throw MeshPacketDecodeError.unknownPacketType(typeRaw)
        }
        let channelByteRaw = data[4]
        let channelByte = MeshChannelByte(rawValue: channelByteRaw) ?? .custom
        let hopCount = data[5]
        let ttl = data[6]
        
        let originUUID  = dataToUUID(data.subdata(in: 7..<23))
        let destRaw     = data.subdata(in: 23..<39)
        let messageUUID = dataToUUID(data.subdata(in: 39..<55))
        
        // Handle version differences
        let conversationID: UUID?
        let payloadLen: Int
        let flagsByte: UInt8
        let sequenceNumber: UInt16
        var relayHistory: [UUID] = []
        var payloadOffset: Int
        
        if version >= 0x03 {
            guard data.count >= fixedHeaderSizeV3 else {
                throw MeshPacketDecodeError.tooShort(got: data.count, need: fixedHeaderSizeV3)
            }
            conversationID = dataToUUID(data.subdata(in: 55..<71))
            let payloadLenBE = data.subdata(in: 71..<75).withUnsafeBytes { $0.load(as: UInt32.self) }
            payloadLen = Int(UInt32(bigEndian: payloadLenBE))
            flagsByte = data[75]
            let seqBE = data.subdata(in: 76..<78).withUnsafeBytes { $0.load(as: UInt16.self) }
            sequenceNumber = UInt16(bigEndian: seqBE)
            
            let historyCount = Int(data[78])
            payloadOffset = fixedHeaderSizeV3 + (historyCount * 16)
            
            guard data.count >= payloadOffset + payloadLen else {
                throw MeshPacketDecodeError.payloadLengthMismatch(declared: payloadLen, available: data.count - payloadOffset)
            }
            
            for i in 0..<historyCount {
                let offset = fixedHeaderSizeV3 + (i * 16)
                if let historyUUID = dataToUUID(data.subdata(in: offset..<offset+16)) {
                    relayHistory.append(historyUUID)
                }
            }
        } else {
            // Version 2 fallback
            conversationID = nil
            let payloadLenBE = data.subdata(in: 55..<59).withUnsafeBytes { $0.load(as: UInt32.self) }
            payloadLen = Int(UInt32(bigEndian: payloadLenBE))
            flagsByte = data[59]
            let seqBE = data.subdata(in: 60..<62).withUnsafeBytes { $0.load(as: UInt16.self) }
            sequenceNumber = UInt16(bigEndian: seqBE)
            payloadOffset = fixedHeaderSizeV2
            
            guard data.count >= payloadOffset + payloadLen else {
                throw MeshPacketDecodeError.payloadLengthMismatch(declared: payloadLen, available: data.count - payloadOffset)
            }
        }
        
        var payload = data.subdata(in: payloadOffset..<(payloadOffset + payloadLen))
        
        // Decode destination (all-zero UUID = BROADCAST)
        let isAllZero = destRaw.allSatisfy { $0 == 0 }
        let destinationUUID: UUID? = isAllZero ? nil : dataToUUID(destRaw)
        
        // Decode custom channel prefix from payload if present with 32-byte safety bounds guard
        var resolvedChannelID = channelByte.toChannelIDString()
        if channelByte == .custom {
            guard !payload.isEmpty else {
                throw MeshPacketDecodeError.malformedCustomChannelPrefix
            }
            let cidLen = Int(payload[0])
            guard cidLen <= maxCustomChannelPrefixBytes else {
                throw MeshPacketDecodeError.customChannelPrefixOverflow(got: cidLen, max: maxCustomChannelPrefixBytes)
            }
            guard payload.count >= 1 + cidLen else {
                throw MeshPacketDecodeError.malformedCustomChannelPrefix
            }
            let cidData = payload.subdata(in: 1..<(1 + cidLen))
            guard let cidString = String(data: cidData, encoding: .utf8) else {
                throw MeshPacketDecodeError.malformedCustomChannelPrefix
            }
            resolvedChannelID = cidString
            payload = payload.subdata(in: (1 + cidLen)..<payload.count)
        }
        
        guard let textPayload = String(data: payload, encoding: .utf8) else {
            throw MeshPacketDecodeError.invalidUTF8Payload
        }
        
        return MeshPacket(
            version: version,
            type: packetType,
            channelByte: channelByte,
            channelID: resolvedChannelID,
            hopCount: hopCount,
            ttl: ttl,
            originUUID: originUUID ?? UUID(),
            destinationUUID: destinationUUID,
            messageID: messageUUID ?? UUID(),
            conversationID: conversationID,
            sequenceNumber: sequenceNumber,
            flags: MeshPacketFlags(raw: flagsByte),
            relayHistory: relayHistory,
            textPayload: textPayload
        )
    }
    
    // MARK: Detection
    
    /// Fast check: does this data begin with the mesh binary magic bytes?
    /// Used in the receive path to route to binary decoder before trying JSON.
    static func isBinaryMeshPacket(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == magicByte0 && data[1] == magicByte1
    }
    
    // MARK: Helpers
    
    private static func uuidToData(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
    
    private static func dataToUUID(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let t: uuid_t = data.withUnsafeBytes { $0.load(as: uuid_t.self) }
        return UUID(uuid: t)
    }
}

// MARK: - MeshPacket → Message bridge

extension MeshPacket {
    /// Reconstructs a `Message` model from a decoded `MeshPacket` for local delivery.
    /// The `localHandle` parameter is used as a fallback sender name when not inferable
    /// from the packet (the binary format does not carry display names).
    func toMessage(senderDisplayName: String = "Mesh Peer") -> Message {
        let destinationStr: String
        if let destUUID = destinationUUID {
            destinationStr = destUUID.uuidString
        } else {
            destinationStr = "BROADCAST"
        }
        
        let msgType: P2PMessageType
        switch type {
        case .text:
            // Preserve transcript vs chat distinction based on payload prefix
            msgType = textPayload.hasPrefix("PTT_TRANSCRIPT:") || textPayload.hasPrefix("[") ? .transcript : .chat
        default:
            msgType = type.toP2PMessageType()
        }
        
        return Message(
            id: messageID,
            originID: originUUID.uuidString,
            destinationID: destinationStr,
            senderID: originUUID.uuidString,
            senderName: senderDisplayName,
            channelID: channelID,
            text: textPayload,
            isSOS: flags.isSOS,
            hopsCount: Int(hopCount),
            ttl: Int(ttl),
            type: msgType,
            protocolVersion: Int(version),
            conversationID: conversationID,
            relayHistory: relayHistory
        )
    }
}
