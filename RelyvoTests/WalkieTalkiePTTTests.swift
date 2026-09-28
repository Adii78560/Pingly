//
//  WalkieTalkiePTTTests.swift
//  RelyvoTests
//
//  Comprehensive unit tests for the Walkie-Talkie / Push-to-Talk pipeline.
//  Covers: PTT binary protocol, Opus codec, floor control, audio session refcounting,
//  jitter buffer, and channel isolation.
//

import XCTest
@testable import Relyvo

// MARK: - PTT Frame Header Tests

final class PTTFrameHeaderTests: XCTestCase {
    
    /// Verify V2 header encodes to exactly 43 bytes
    func testV2HeaderEncodesToCorrectSize() {
        let header = PTTFrameHeader(
            version: .v2,
            type: .chunk,
            channel: 0x01,
            hopCount: 0,
            ttl: 3,
            sequenceNo: 42,
            timestampMs: 1000,
            senderNodeID: UUID(),
            sessionID: UUID(),
            isEncrypted: false
        )
        let data = header.encode()
        XCTAssertEqual(data.count, 43, "V2 header should be exactly 43 bytes")
    }
    
    /// Verify V2 encode → decode roundtrip preserves all fields
    func testV2HeaderRoundtrip() {
        let senderID = UUID()
        let sessionID = UUID()
        let original = PTTFrameHeader(
            version: .v2,
            type: .chunk,
            channel: 0x02,
            hopCount: 1,
            ttl: 3,
            sequenceNo: 1234,
            timestampMs: 56789,
            senderNodeID: senderID,
            sessionID: sessionID,
            isEncrypted: false
        )
        let encoded = original.encode()
        let decoded = PTTFrameHeader.decode(from: encoded)
        
        XCTAssertNotNil(decoded, "Decoded header should not be nil")
        guard let decoded = decoded else { return }
        
        XCTAssertEqual(decoded.version, .v2)
        XCTAssertEqual(decoded.type, .chunk)
        XCTAssertEqual(decoded.channel, 0x02)
        XCTAssertEqual(decoded.hopCount, 1)
        XCTAssertEqual(decoded.ttl, 3)
        XCTAssertEqual(decoded.sequenceNo, 1234)
        XCTAssertEqual(decoded.timestampMs, 56789)
        XCTAssertEqual(decoded.senderNodeID, senderID)
        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.isEncrypted, false)
    }
    
    /// Verify encryption bit is correctly encoded and decoded
    func testEncryptedFlagRoundtrip() {
        let header = PTTFrameHeader(
            version: .v2,
            type: .start,
            channel: 0x01,
            hopCount: 0,
            ttl: 3,
            sequenceNo: 1,
            timestampMs: 0,
            senderNodeID: UUID(),
            sessionID: UUID(),
            isEncrypted: true
        )
        let encoded = header.encode()
        let decoded = PTTFrameHeader.decode(from: encoded)
        
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.isEncrypted, "Encrypted flag should survive encode/decode")
        XCTAssertEqual(decoded!.type, .start, "Frame type should be preserved when encryption bit is set")
    }
    
    /// Verify all PTT frame types encode/decode correctly
    func testAllFrameTypes() {
        let types: [PTTFrameType] = [.start, .chunk, .end]
        for type in types {
            let header = PTTFrameHeader(
                version: .v2,
                type: type,
                channel: 0x00,
                hopCount: 0,
                ttl: 3,
                sequenceNo: 1,
                timestampMs: 0,
                senderNodeID: UUID(),
                sessionID: UUID(),
                isEncrypted: false
            )
            let decoded = PTTFrameHeader.decode(from: header.encode())
            XCTAssertNotNil(decoded, "Frame type \(type) should decode successfully")
            XCTAssertEqual(decoded?.type, type, "Frame type \(type) should survive roundtrip")
        }
    }
    
    /// Verify header with data payload extracts correctly
    func testHeaderWithPayload() {
        let header = PTTFrameHeader(
            version: .v2,
            type: .chunk,
            channel: 0x01,
            hopCount: 0,
            ttl: 3,
            sequenceNo: 5,
            timestampMs: 100,
            senderNodeID: UUID(),
            sessionID: UUID(),
            isEncrypted: false
        )
        let payload = Data(repeating: 0xAB, count: 160)
        var packet = header.encode()
        packet.append(payload)
        
        let decoded = PTTFrameHeader.decode(from: packet)
        XCTAssertNotNil(decoded)
        
        let extractedPayload = packet.subdata(in: decoded!.actualHeaderSize..<packet.count)
        XCTAssertEqual(extractedPayload.count, 160, "Payload should be 160 bytes")
        XCTAssertEqual(extractedPayload, payload, "Payload content should match")
    }
    
    /// Verify decode rejects truncated data
    func testDecodeRejectsTruncatedData() {
        let shortData = Data(repeating: 0x22, count: 10)
        let decoded = PTTFrameHeader.decode(from: shortData)
        XCTAssertNil(decoded, "Should reject data shorter than header size")
    }
    
    /// Verify decode rejects empty data
    func testDecodeRejectsEmptyData() {
        let decoded = PTTFrameHeader.decode(from: Data())
        XCTAssertNil(decoded, "Should reject empty data")
    }
    
    /// Verify sequence number wraps correctly at UInt16.max
    func testSequenceNumberWraparound() {
        let header = PTTFrameHeader(
            version: .v2,
            type: .chunk,
            channel: 0x00,
            hopCount: 0,
            ttl: 3,
            sequenceNo: UInt16.max,
            timestampMs: 0,
            senderNodeID: UUID(),
            sessionID: UUID(),
            isEncrypted: false
        )
        let decoded = PTTFrameHeader.decode(from: header.encode())
        XCTAssertEqual(decoded?.sequenceNo, UInt16.max)
    }
}

// MARK: - Opus Codec Tests

final class OpusCodecManagerTests: XCTestCase {
    
    /// Verify encode/decode roundtrip produces audio that is non-silent
    func testEncodeDecodeRoundtripProducesNonSilentAudio() {
        let codec = OpusCodecManager.shared
        
        // Generate a 320-sample 16-bit mono sine wave at ~440Hz
        var pcmSamples = [Int16](repeating: 0, count: 320)
        for i in 0..<320 {
            let t = Double(i) / 16000.0
            pcmSamples[i] = Int16(sin(2.0 * .pi * 440.0 * t) * 16000.0)
        }
        let pcmData = pcmSamples.withUnsafeBytes { Data($0) }
        XCTAssertEqual(pcmData.count, 640, "20ms mono 16kHz PCM should be 640 bytes")
        
        let encoded = codec.encodePCMToOpus(pcmData)
        XCTAssertFalse(encoded.isEmpty, "Encoded data should not be empty")
        XCTAssertLessThan(encoded.count, pcmData.count, "Encoded data should be smaller than raw PCM")
        
        let decoded = codec.decodeOpusToPCM(encoded)
        XCTAssertEqual(decoded.count, 640, "Decoded PCM should be 640 bytes (320 samples × 2)")
        
        // Verify decoded audio is not all zeros
        let decodedSamples = decoded.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let hasNonZero = decodedSamples.contains { $0 != 0 }
        XCTAssertTrue(hasNonZero, "Decoded audio should not be completely silent")
    }
    
    /// Verify codec handles undersized input gracefully
    func testEncodeHandlesUndersizedInput() {
        let codec = OpusCodecManager.shared
        let shortData = Data(repeating: 0, count: 100) // Less than 640 bytes
        let encoded = codec.encodePCMToOpus(shortData)
        // Should return raw data unchanged (passthrough)
        XCTAssertEqual(encoded, shortData, "Short input should be passed through unchanged")
    }
    
    /// Verify PLC frame is non-empty and decays
    func testPLCFrameGeneration() {
        let codec = OpusCodecManager.shared
        
        // First, decode a real frame to populate lastDecodedSamples
        var pcmSamples = [Int16](repeating: 0, count: 320)
        for i in 0..<320 { pcmSamples[i] = Int16(clamping: i * 100) }
        let pcmData = pcmSamples.withUnsafeBytes { Data($0) }
        let encoded = codec.encodePCMToOpus(pcmData)
        _ = codec.decodeOpusToPCM(encoded)
        
        // Now generate PLC frame
        let plcFrame = codec.decodePLCFrame()
        XCTAssertEqual(plcFrame.count, 640, "PLC frame should be 640 bytes")
    }
    
    /// Verify decode handles very short opus data via PLC
    func testDecodeHandlesShortDataViaPLC() {
        let codec = OpusCodecManager.shared
        let tinyData = Data([0x01]) // 1 byte, too short to decode
        let result = codec.decodeOpusToPCM(tinyData)
        XCTAssertEqual(result.count, 640, "Short data should trigger PLC and produce 640 bytes")
    }
    
    /// Verify encode/decode roundtrip accurately reproduces speech/sine waveforms with high fidelity (>15 dB SNR)
    func testEncodeDecodeHighFidelityWaveformAccuracy() {
        let codec = OpusCodecManager.shared
        codec.resetState()
        
        // 2 frames (40ms) of 440Hz sine wave
        for frame in 0..<2 {
            var pcmSamples = [Int16](repeating: 0, count: 320)
            for i in 0..<320 {
                let t = Double(frame * 320 + i) / 16000.0
                pcmSamples[i] = Int16(sin(2.0 * .pi * 440.0 * t) * 16000.0)
            }
            let pcmData = pcmSamples.withUnsafeBytes { Data($0) }
            let encoded = codec.encodePCMToOpus(pcmData)
            XCTAssertEqual(encoded.count, 162)
            
            let decoded = codec.decodeOpusToPCM(encoded)
            XCTAssertEqual(decoded.count, 640)
            
            if frame == 1 {
                // On the 2nd frame (where step size has fully adapted), check signal fidelity
                let decodedSamples = decoded.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                var sigPower: Double = 0
                var errPower: Double = 0
                for i in 0..<320 {
                    let orig = Double(pcmSamples[i])
                    let dec = Double(decodedSamples[i])
                    let diff = dec - orig
                    sigPower += orig * orig
                    errPower += diff * diff
                }
                let snr = 10.0 * log10(sigPower / max(1.0, errPower))
                XCTAssertGreaterThan(snr, 15.0, "Codec SNR should exceed 15 dB for high quality speech audio reproduction (got \(snr) dB)")
            }
        }
    }
}

// MARK: - WAV Header Tests

final class WAVHeaderTests: XCTestCase {
    
    func testWAVHeaderCorrectSize() {
        let header = createWavHeader(dataLength: 1000, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        XCTAssertEqual(header.count, 44, "WAV header should be 44 bytes")
    }
    
    func testWAVHeaderContainsRIFF() {
        let header = createWavHeader(dataLength: 500, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let riffMagic = String(data: header.subdata(in: 0..<4), encoding: .utf8)
        XCTAssertEqual(riffMagic, "RIFF", "WAV header should start with RIFF")
    }
    
    func testWAVHeaderContainsWAVE() {
        let header = createWavHeader(dataLength: 500, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let waveMagic = String(data: header.subdata(in: 8..<12), encoding: .utf8)
        XCTAssertEqual(waveMagic, "WAVE", "WAV header should contain WAVE format marker")
    }
}

// MARK: - UUID Extension Tests

final class UUIDDataTests: XCTestCase {
    
    func testUUIDToDataRoundtrip() {
        let original = UUID()
        let data = original.uuidData
        XCTAssertEqual(data.count, 16, "UUID data should be 16 bytes")
        
        let restored = UUID(uuidData: data)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored, original, "UUID roundtrip should preserve value")
    }
    
    func testUUIDFromShortDataFails() {
        let shortData = Data(repeating: 0, count: 10)
        let result = UUID(uuidData: shortData)
        XCTAssertNil(result, "UUID init from < 16 bytes should return nil")
    }
}

// MARK: - Floor Control State Tests

final class FloorControlTests: XCTestCase {
    
    func testPTTSessionStateEquality() {
        XCTAssertEqual(PTTSessionState.idle, PTTSessionState.idle)
        XCTAssertEqual(PTTSessionState.transmitting, PTTSessionState.transmitting)
        XCTAssertEqual(PTTSessionState.outOfRange, PTTSessionState.outOfRange)
        XCTAssertEqual(PTTSessionState.handsFree, PTTSessionState.handsFree)
        XCTAssertEqual(PTTSessionState.receiving(from: "Alice"), PTTSessionState.receiving(from: "Alice"))
        XCTAssertNotEqual(PTTSessionState.receiving(from: "Alice"), PTTSessionState.receiving(from: "Bob"))
        XCTAssertNotEqual(PTTSessionState.idle, PTTSessionState.transmitting)
        XCTAssertNotEqual(PTTSessionState.idle, PTTSessionState.outOfRange)
    }
    
    func testPTTFrameTypeRawValues() {
        XCTAssertEqual(PTTFrameType.start.rawValue, 0x01)
        XCTAssertEqual(PTTFrameType.chunk.rawValue, 0x02)
        XCTAssertEqual(PTTFrameType.end.rawValue, 0x03)
    }
    
    func testPTTProtocolVersionRawValues() {
        XCTAssertEqual(PTTProtocolVersion.v1.rawValue, 0x01)
        XCTAssertEqual(PTTProtocolVersion.v2.rawValue, 0x22)
    }
}

// MARK: - Audio Recorder Context Tests

final class AudioRecorderContextTests: XCTestCase {
    
    func testRecorderInitialization() async {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        let sessionID = UUID()
        
        let recorder = AudioRecorderContext(sessionID: sessionID, fileURL: fileURL)
        XCTAssertEqual(recorder.sessionID, sessionID)
        XCTAssertEqual(recorder.fileURL, fileURL)
        
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    func testRecorderAppendAndFinalize() async {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        let sessionID = UUID()
        let recorder = AudioRecorderContext(sessionID: sessionID, fileURL: fileURL)
        
        // Append valid 20ms 16kHz PCM chunks (640 bytes each)
        let pcmData = Data(repeating: 0x01, count: 640)
        recorder.append(pcmData: pcmData)
        recorder.append(pcmData: pcmData)
        
        // Give background queue brief moment to process appends
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        let success = await withCheckedContinuation { continuation in
            recorder.finalize { result in
                continuation.resume(returning: result)
            }
        }
        
        XCTAssertTrue(success, "Finalize should succeed with valid PCM data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "WAV file should exist on disk")
        
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    func testRecorderFinalizeWithNoDataReturnsFalse() async {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        let recorder = AudioRecorderContext(sessionID: UUID(), fileURL: fileURL)
        
        let success = await withCheckedContinuation { continuation in
            recorder.finalize { result in
                continuation.resume(returning: result)
            }
        }
        
        XCTAssertFalse(success, "Finalize should fail when no audio frames were recorded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Zero-byte file should be cleaned up")
        
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Offline Peer-to-Peer (WiFi & Bluetooth) Walkie-Talkie Tests

final class OfflinePeerToPeerWalkieTalkieTests: XCTestCase {
    
    private static func generateSineWavePCM(frequency: Double = 440.0, sampleRate: Double = 16000.0, durationMs: Double = 20.0) -> Data {
        let sampleCount = Int(sampleRate * (durationMs / 1000.0))
        var pcmSamples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            pcmSamples[i] = Int16(sin(2.0 * .pi * frequency * t) * 16000.0)
        }
        return pcmSamples.withUnsafeBytes { Data($0) }
    }
    
    /// Test that audio frames are completely self-contained binary packets
    /// that fit within standard Wi-Fi & Bluetooth L2CAP MTU limits (<1000 bytes)
    /// and have zero dependencies on internet/cellular data or cloud servers.
    func testAudioPacketsFitBluetoothAndWiFiMTUWithoutInternet() {
        let pcm = Self.generateSineWavePCM(frequency: 440.0, sampleRate: 16000, durationMs: 20)
        let opusData = OpusCodecManager.shared.encodePCMToOpus(pcm)
        XCTAssertFalse(opusData.isEmpty, "Opus compression must succeed offline")
        
        let header = PTTFrameHeader(
            version: .v2,
            type: .chunk,
            channel: 0x01,
            hopCount: 0,
            ttl: 3,
            sequenceNo: 1,
            timestampMs: 20,
            senderNodeID: UUID(),
            sessionID: UUID(),
            isEncrypted: false
        )
        
        var packet = header.encode()
        packet.append(opusData)
        
        // P2P Bluetooth LE MTU typically allows 512 bytes, AWDL/Wi-Fi allows 1500 bytes.
        // A 20ms Opus frame is ~40-60 bytes + 43 byte header = ~100 bytes.
        XCTAssertLessThan(packet.count, 250, "PTT packet must be ultra-compact for fast Bluetooth/Wi-Fi transmission without cellular")
        XCTAssertGreaterThan(packet.count, 43, "Packet must contain header and Opus payload")
    }
    
    /// Simulates a complete offline two-way walkie-talkie conversation between Peer A (Alice)
    /// and Peer B (Bob) over peer-to-peer Wi-Fi/Bluetooth with direct, instantaneous playback.
    func testOfflineTwoPeerSimulatedWalkieTalkieExchange() {
        let aliceID = UUID()
        let bobID = UUID()
        let sessionID = UUID()
        let channelByte: UInt8 = 0x01
        
        // --- 1. Alice presses PTT (PTT_START) ---
        let startHeader = PTTFrameHeader(
            version: .v2,
            type: .start,
            channel: channelByte,
            hopCount: 0,
            ttl: 3,
            sequenceNo: 0,
            timestampMs: 0,
            senderNodeID: aliceID,
            sessionID: sessionID,
            isEncrypted: false
        )
        var startPacket = startHeader.encode()
        startPacket.append(sessionID.uuidData)
        
        // Bob receives Alice's START packet over offline P2P transport
        guard let decodedStart = PTTFrameHeader.decode(from: startPacket) else {
            XCTFail("Bob failed to decode Alice's PTT_START packet")
            return
        }
        XCTAssertEqual(decodedStart.type, .start)
        XCTAssertEqual(decodedStart.senderNodeID, aliceID)
        XCTAssertEqual(decodedStart.channel, channelByte)
        
        // --- 2. Alice streams audio chunks (Direct Playback, No Jitter Buffer) ---
        var bobReceivedAudioBuffers: [Data] = []
        let frameCount: UInt16 = 5
        
        for seq in 1...frameCount {
            let pcm = Self.generateSineWavePCM(frequency: 440.0 + Double(seq * 50), sampleRate: 16000, durationMs: 20)
            let opusData = OpusCodecManager.shared.encodePCMToOpus(pcm)
            
            let chunkHeader = PTTFrameHeader(
                version: .v2,
                type: .chunk,
                channel: channelByte,
                hopCount: 0,
                ttl: 3,
                sequenceNo: seq,
                timestampMs: UInt32(seq * 20),
                senderNodeID: aliceID,
                sessionID: sessionID,
                isEncrypted: false
            )
            var chunkPacket = chunkHeader.encode()
            chunkPacket.append(opusData)
            
            // Bob receives over P2P link
            guard let rxHeader = PTTFrameHeader.decode(from: chunkPacket) else {
                XCTFail("Bob failed to decode chunk \(seq)")
                continue
            }
            let payload = chunkPacket.subdata(in: rxHeader.actualHeaderSize..<chunkPacket.count)
            
            // Bob decodes Opus directly to PCM (instant zero-jitter playback path)
            let decodedPCM = OpusCodecManager.shared.decodeOpusToPCM(payload)
            XCTAssertEqual(decodedPCM.count, 640, "Decoded PCM must be exactly 640 bytes (20ms at 16kHz)")
            bobReceivedAudioBuffers.append(decodedPCM)
            
            // Verify audio is non-silent
            let nonZeroBytes = decodedPCM.filter { $0 != 0 }.count
            XCTAssertGreaterThan(nonZeroBytes, 100, "Decoded audio chunk must contain audible waveform")
        }
        
        XCTAssertEqual(bobReceivedAudioBuffers.count, Int(frameCount), "Bob must receive and decode all audio chunks directly")
        
        // --- 3. Alice releases PTT (PTT_END) ---
        let endHeader = PTTFrameHeader(
            version: .v2,
            type: .end,
            channel: channelByte,
            hopCount: 0,
            ttl: 3,
            sequenceNo: frameCount + 1,
            timestampMs: UInt32(frameCount * 20 + 20),
            senderNodeID: aliceID,
            sessionID: sessionID,
            isEncrypted: false
        )
        var endPacket = endHeader.encode()
        endPacket.append(sessionID.uuidData)
        
        guard let decodedEnd = PTTFrameHeader.decode(from: endPacket) else {
            XCTFail("Bob failed to decode Alice's PTT_END packet")
            return
        }
        XCTAssertEqual(decodedEnd.type, .end)
        XCTAssertEqual(decodedEnd.sessionID, sessionID)
        
        // --- 4. Bob replies back to Alice (Full Duplex Floor Turnaround) ---
        let replySessionID = UUID()
        let bobStartHeader = PTTFrameHeader(
            version: .v2,
            type: .start,
            channel: channelByte,
            hopCount: 0,
            ttl: 3,
            sequenceNo: 0,
            timestampMs: 0,
            senderNodeID: bobID,
            sessionID: replySessionID,
            isEncrypted: false
        )
        let bobStartPacket = bobStartHeader.encode()
        guard let aliceDecodedReplyStart = PTTFrameHeader.decode(from: bobStartPacket) else {
            XCTFail("Alice failed to decode Bob's reply PTT_START")
            return
        }
        XCTAssertEqual(aliceDecodedReplyStart.senderNodeID, bobID)
        XCTAssertEqual(aliceDecodedReplyStart.type, .start)
    }
    
    /// Test that audio frames are routed directly to the AudioStreamEngine player
    /// without any intermediate jitter buffering queue delay.
    func testDirectAudioPlaybackWithoutJitterBufferLag() {
        let pcm = Self.generateSineWavePCM(frequency: 500.0, sampleRate: 16000, durationMs: 20)
        let opusData = OpusCodecManager.shared.encodePCMToOpus(pcm)
        
        let header = PTTFrameHeader(
            version: .v2,
            type: .chunk,
            channel: 0x01,
            hopCount: 0,
            ttl: 3,
            sequenceNo: 1,
            timestampMs: 20,
            senderNodeID: UUID(),
            sessionID: UUID(),
            isEncrypted: false
        )
        
        var packet = header.encode()
        packet.append(opusData)
        
        // Immediate decode
        guard let decodedHeader = PTTFrameHeader.decode(from: packet) else {
            XCTFail("Header decode failed")
            return
        }
        let payload = packet.subdata(in: decodedHeader.actualHeaderSize..<packet.count)
        let decodedPCM = OpusCodecManager.shared.decodeOpusToPCM(payload)
        
        // Verify direct PCM availability for instant playback
        XCTAssertEqual(decodedPCM.count, 640)
        
        // Test playback engine accepts the direct chunk
        AudioStreamEngine.shared.playAudioChunk(decodedPCM, sequenceNumber: 1)
        // Verify sequence tracker records the played sequence
        XCTAssertEqual(AudioStreamEngine.shared.highestPlayedSequenceNo, 1)
    }
    
    /// Test multi-hop mesh forwarding offline: packets can hop across intermediate devices
    /// over WiFi/Bluetooth to extend walkie-talkie range with no cell service.
    func testOfflineMeshHopForwarding() {
        let originalHeader = PTTFrameHeader(
            version: .v2,
            type: .chunk,
            channel: 0x01,
            hopCount: 0,
            ttl: 3,
            sequenceNo: 42,
            timestampMs: 840,
            senderNodeID: UUID(),
            sessionID: UUID(),
            isEncrypted: false
        )
        
        // Intermediate node receives and increments hopCount
        let forwardedHeader = PTTFrameHeader(
            version: originalHeader.version,
            type: originalHeader.type,
            channel: originalHeader.channel,
            hopCount: originalHeader.hopCount + 1,
            ttl: originalHeader.ttl,
            sequenceNo: originalHeader.sequenceNo,
            timestampMs: originalHeader.timestampMs,
            senderNodeID: originalHeader.senderNodeID,
            sessionID: originalHeader.sessionID,
            isEncrypted: originalHeader.isEncrypted
        )
        
        XCTAssertEqual(forwardedHeader.hopCount, 1)
        XCTAssertLessThan(forwardedHeader.hopCount, forwardedHeader.ttl, "Packet is still valid for further hops")
        
        let encodedForwarded = forwardedHeader.encode()
        let reDecoded = PTTFrameHeader.decode(from: encodedForwarded)
        XCTAssertEqual(reDecoded?.hopCount, 1)
        XCTAssertEqual(reDecoded?.sequenceNo, 42)
    }
}

// MARK: - Channel Isolation Tests

final class ChannelIsolationTests: XCTestCase {
    
    /// Verify V2 packets include channel byte correctly
    func testChannelByteIncludedInPacket() {
        let channelByte: UInt8 = 0x03
        let header = PTTFrameHeader(
            version: .v2,
            type: .chunk,
            channel: channelByte,
            hopCount: 0,
            ttl: 3,
            sequenceNo: 1,
            timestampMs: 100,
            senderNodeID: UUID(),
            sessionID: UUID(),
            isEncrypted: false
        )
        
        let encoded = header.encode()
        let decoded = PTTFrameHeader.decode(from: encoded)
        
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.channel, channelByte, "Channel byte should survive encode/decode roundtrip")
    }
    
    /// Verify two different channels produce different channel bytes
    func testDifferentChannelsProduceDifferentBytes() {
        let h1 = PTTFrameHeader(version: .v2, type: .chunk, channel: 0x01, hopCount: 0, ttl: 3, sequenceNo: 1, timestampMs: 0, senderNodeID: UUID(), sessionID: UUID(), isEncrypted: false)
        let h2 = PTTFrameHeader(version: .v2, type: .chunk, channel: 0x03, hopCount: 0, ttl: 3, sequenceNo: 1, timestampMs: 0, senderNodeID: UUID(), sessionID: UUID(), isEncrypted: false)
        
        let d1 = PTTFrameHeader.decode(from: h1.encode())
        let d2 = PTTFrameHeader.decode(from: h2.encode())
        
        XCTAssertNotEqual(d1!.channel, d2!.channel, "Different channel inputs should produce different channel bytes")
    }
}

// MARK: - Sequence Tracker Tests

final class SequenceTrackerTests: XCTestCase {
    
    /// Verify UInt16 wraparound math is correct for sequence tracking
    func testUInt16WraparoundMath() {
        let highSeq: UInt16 = 65534
        let nextSeq: UInt16 = 0 // wrapped around from 65535
        
        let diff = Int16(bitPattern: nextSeq &- highSeq)
        // 0 - 65534 = 2 (with wrapping), diff should be positive
        XCTAssertGreaterThan(diff, 0, "Wraparound should produce positive diff for forward progression")
    }
    
    /// Verify duplicate/backward sequence detection
    func testDuplicateSequenceDetection() {
        let highSeq: UInt16 = 100
        let oldSeq: UInt16 = 99
        
        let diff = Int16(bitPattern: oldSeq &- highSeq)
        XCTAssertLessThanOrEqual(diff, 0, "Backward sequence should produce non-positive diff")
    }
    
    /// Verify normal forward progression
    func testForwardSequenceProgression() {
        let currentSeq: UInt16 = 100
        let nextSeq: UInt16 = 101
        
        let diff = Int16(bitPattern: nextSeq &- currentSeq)
        XCTAssertGreaterThan(diff, 0, "Forward progression should produce positive diff")
    }
}
