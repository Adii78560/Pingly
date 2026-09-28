//
//  OpusCodecManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import os

/// High-performance Audio Codec Manager implementing 16kHz Wideband speech encoding,
/// decoding, and built-in Packet Loss Concealment (PLC) via 4-bit Adaptive Differential Pulse Code Modulation (IMA-ADPCM).
final class OpusCodecManager {
    
    static let shared = OpusCodecManager()
    
    private let sampleRate: Int32 = 16000
    private let channels: Int32 = 1
    private let frameSizeSamples: Int = 320 // 20ms at 16kHz = 320 samples
    private let pcmBytesPerFrame: Int = 640 // 320 samples * 2 bytes = 640 bytes
    
    // IMA-ADPCM Quantization Step Sizes (89 levels from 7 to 32767)
    private let stepSizeTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
    
    // IMA-ADPCM Step Index Adaptation Table (-1 for small delta, up to +8 for large slope)
    private let indexTable: [Int32] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8
    ]
    
    private var encStepIndex: Int = 16
    private var decStepIndex: Int = 16
    private var lastDecodedSamples: [Int16] = Array(repeating: 0, count: 320)
    
    private init() {}
    
    /// Resets adaptive predictor and step indices when a new PTT session begins.
    func resetState() {
        encStepIndex = 16
        decStepIndex = 16
        lastDecodedSamples = Array(repeating: 0, count: frameSizeSamples)
    }
    
    // MARK: - Audio Encoding (640 Bytes PCM -> 162 Bytes Compressed Packet ~64kbps Wideband)
    
    /// Encodes a 20ms raw 16kHz Int16 PCM audio frame (320 samples / 640 bytes) into a compressed 162-byte packet.
    func encodePCMToOpus(_ pcmData: Data) -> Data {
        guard pcmData.count >= pcmBytesPerFrame else { return pcmData }
        
        var encodedBuffer = Data(capacity: 162)
        pcmData.withUnsafeBytes { rawPtr in
            guard let pcmPtr = rawPtr.bindMemory(to: Int16.self).baseAddress else { return }
            
            // Frame Header: 1st sample as baseline predictor (2 bytes, big-endian)
            let firstSample = pcmPtr[0]
            let firstSampleBE = firstSample.bigEndian
            withUnsafeBytes(of: firstSampleBE) { encodedBuffer.append(contentsOf: $0) }
            
            var predicted = Int32(firstSample)
            var stepIndex = self.encStepIndex
            
            // Encode the remaining 319 samples as 4-bit adaptive nibbles
            var nibbles = [UInt8]()
            nibbles.reserveCapacity(320)
            
            for i in 1..<frameSizeSamples {
                let sample = Int32(pcmPtr[i])
                var diff = sample - predicted
                let sign: UInt8 = (diff < 0) ? 8 : 0
                if sign != 0 {
                    diff = -diff
                }
                
                var step = stepSizeTable[stepIndex]
                var delta: UInt8 = 0
                var vpdiff = step >> 3
                
                if diff >= step {
                    delta |= 4
                    diff -= step
                    vpdiff += step
                }
                step >>= 1
                if diff >= step {
                    delta |= 2
                    diff -= step
                    vpdiff += step
                }
                step >>= 1
                if diff >= step {
                    delta |= 1
                    vpdiff += step
                }
                
                // Reconstruct predicted sample identically to decoder
                if sign != 0 {
                    predicted = max(-32768, predicted - vpdiff)
                } else {
                    predicted = min(32767, predicted + vpdiff)
                }
                
                let nibble = delta | sign
                nibbles.append(nibble)
                
                // Adapt step size index for next sample
                let indexDelta = indexTable[Int(nibble)]
                stepIndex = min(max(stepIndex + Int(indexDelta), 0), 88)
            }
            
            self.encStepIndex = stepIndex
            
            // Pack 319 nibbles (+1 zero pad nibble) into 160 bytes
            let nibbleCount = nibbles.count
            for i in stride(from: 0, to: nibbleCount, by: 2) {
                let n1 = nibbles[i]
                let n2 = (i + 1 < nibbleCount) ? nibbles[i + 1] : 0
                encodedBuffer.append((n1 << 4) | (n2 & 0x0F))
            }
        }
        
        return encodedBuffer
    }
    
    // MARK: - Audio Decoding (162 Bytes Compressed Packet -> 640 Bytes PCM)
    
    /// Decodes a compressed packet back into a 20ms raw 16kHz Int16 PCM frame (320 samples / 640 bytes).
    func decodeOpusToPCM(_ opusData: Data) -> Data {
        guard opusData.count >= 2 else { return decodePLCFrame() }
        
        var pcmSamples = [Int16]()
        pcmSamples.reserveCapacity(frameSizeSamples)
        
        // Read 1st sample baseline predictor
        let firstSampleBE = opusData.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: Int16.self) }
        var predicted = Int32(Int16(bigEndian: firstSampleBE))
        pcmSamples.append(Int16(clamping: predicted))
        
        var stepIndex = self.decStepIndex
        let payloadBytes = opusData.subdata(in: 2..<opusData.count)
        
        for byte in payloadBytes {
            let n1 = (byte >> 4) & 0x0F
            let n2 = byte & 0x0F
            
            for nibble in [n1, n2] {
                if pcmSamples.count >= frameSizeSamples {
                    break
                }
                
                let step = stepSizeTable[stepIndex]
                var vpdiff = step >> 3
                if (nibble & 4) != 0 { vpdiff += step }
                if (nibble & 2) != 0 { vpdiff += step >> 1 }
                if (nibble & 1) != 0 { vpdiff += step >> 2 }
                
                if (nibble & 8) != 0 {
                    predicted = max(-32768, predicted - vpdiff)
                } else {
                    predicted = min(32767, predicted + vpdiff)
                }
                
                pcmSamples.append(Int16(clamping: predicted))
                
                let indexDelta = indexTable[Int(nibble)]
                stepIndex = min(max(stepIndex + Int(indexDelta), 0), 88)
            }
        }
        
        self.decStepIndex = stepIndex
        
        while pcmSamples.count < frameSizeSamples {
            pcmSamples.append(Int16(clamping: predicted))
        }
        
        self.lastDecodedSamples = pcmSamples
        return pcmSamples.withUnsafeBytes { Data($0) }
    }
    
    // MARK: - Built-in Packet Loss Concealment (PLC) Engine
    
    /// Synthesizes a plausible 20ms continuation PCM audio frame when a packet drop gap occurs.
    func decodePLCFrame() -> Data {
        var plcSamples = [Int16](repeating: 0, count: frameSizeSamples)
        
        let lastSampleCount = lastDecodedSamples.count
        let lastVal = Double(lastDecodedSamples.last ?? 0)
        let prevVal = Double(lastDecodedSamples[max(0, lastSampleCount - 16)])
        let slope = (lastVal - prevVal) / 16.0
        
        for i in 0..<frameSizeSamples {
            let fadeFactor = pow(0.992, Double(i))
            let synthesized = (lastVal + (slope * Double(i))) * fadeFactor
            let clamped = min(max(synthesized, -32768.0), 32767.0)
            plcSamples[i] = Int16(clamped)
        }
        
        self.lastDecodedSamples = plcSamples
        return plcSamples.withUnsafeBytes { Data($0) }
    }
}
