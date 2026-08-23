//
//  SpeechTranscriberManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import Speech
import AVFoundation
import Combine
import os

struct VoiceTranscript: Identifiable, Equatable {
    let id: UUID
    let speakerName: String
    let text: String
    let channel: String
    let timestamp: Date
    var isDelivered: Bool
    var sessionID: UUID?
    
    init(
        id: UUID = UUID(),
        speakerName: String,
        text: String,
        channel: String = "CH-1 EMERGENCY",
        timestamp: Date = Date(),
        isDelivered: Bool = false,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.speakerName = speakerName
        self.text = text
        self.channel = channel
        self.timestamp = timestamp
        self.isDelivered = isDelivered
        self.sessionID = sessionID
    }
}


/// Manages real-time speech-to-text transcription during Walkie-Talkie voice broadcasts.
final class SpeechTranscriberManager: ObservableObject {
    
    static let shared = SpeechTranscriberManager()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var currentTranscriptText: String = ""
    @Published private(set) var transcriptHistory: [VoiceTranscript] = []
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeSpeakerName: String = "Unknown"
    private var activeChannel: String = "CH-1 EMERGENCY"
    private var accumulatedSegments: [String] = []
    
    private init() {
        requestAuthorization()
    }
    
    private func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .authorized:
                AppLogger.audio.info("Speech recognition authorized")
            case .denied, .restricted, .notDetermined:
                AppLogger.audio.warning("Speech recognition authorization status: \(status.rawValue)")
            @unknown default:
                break
            }
        }
    }
    
    var currentSessionID: UUID?
    
    // MARK: - Public Control API
    
    /// Starts live speech-to-text transcription for active speaker.
    func startTranscribing(speakerName: String, channel: String = "CH-1 EMERGENCY", sessionID: UUID? = nil) {
        guard !isTranscribing else { return }
        self.activeSpeakerName = speakerName
        self.activeChannel = channel
        self.currentTranscriptText = ""
        self.accumulatedSegments.removeAll()
        self.currentSessionID = sessionID
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            AppLogger.audio.warning("SFSpeechRecognizer is NOT available. Active locale: \(self.speechRecognizer?.locale.identifier ?? "none")")
            self.isTranscribing = true
            return
        }
        
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        
        self.recognitionRequest = request

        
        AppLogger.audio.info("SFSpeechRecognizer available. supportsOnDevice: \(recognizer.supportsOnDeviceRecognition)")
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                AppLogger.audio.error("SFSpeechRecognitionTask error: \(error.localizedDescription)")
            }
            
            if let result = result {
                let latestString = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                AppLogger.audio.info("SFSpeechRecognitionTask text: \"\(latestString)\" (isFinal: \(result.isFinal))")
                
                DispatchQueue.main.async {
                    var parts = self.accumulatedSegments
                    if !latestString.isEmpty {
                        parts.append(latestString)
                    }
                    let fullText = parts.joined(separator: " ")
                    self.currentTranscriptText = fullText
                    
                    if result.isFinal && !latestString.isEmpty {
                        if !self.accumulatedSegments.contains(latestString) {
                            self.accumulatedSegments.append(latestString)
                        }
                    }
                }
            }
        }


        
        self.isTranscribing = true
        AppLogger.audio.info("Speech transcription started for speaker: \(speakerName) on channel: \(channel)")
    }
    
    /// Appends incoming audio PCM buffer to the speech recognition pipeline.
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isTranscribing else { return }
        guard let request = recognitionRequest else {
            return
        }
        request.append(buffer)
    }

    
    /// Stops speech transcription and saves completed transcript to history.
    func stopTranscribing() {
        guard isTranscribing else { return }
        isTranscribing = false
        
        recognitionRequest?.endAudio()
        
        let finalSpeaker = activeSpeakerName
        let channel = activeChannel
        
        // Allow 350ms for final speech recognition segments to arrive from Apple Speech NPU
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            
            self.recognitionTask?.finish()
            self.recognitionTask = nil
            self.recognitionRequest = nil
            
            let textToSave = self.currentTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.currentTranscriptText = ""
            self.accumulatedSegments.removeAll()

            
            // Only save transcript if actual spoken text was recognized
            guard !textToSave.isEmpty else {
                AppLogger.audio.info("No speech detected during PTT broadcast; ignoring empty transcript.")
                return
            }
            
            let isConnected = !MultipeerService.shared.connectedPeers.isEmpty
            
            let sessionIDToSave = self.currentSessionID
            
            // Persist VoiceTranscript to SwiftData with initial delivery status indicator (Gray offline)
            let sdTranscript = SwiftDataService.shared.saveVoiceTranscript(
                speakerName: finalSpeaker,
                text: textToSave,
                channel: channel,
                isDelivered: false,
                sessionID: sessionIDToSave
            )
            
            let transcript = VoiceTranscript(
                id: sdTranscript.id,
                speakerName: finalSpeaker,
                text: textToSave,
                channel: channel,
                isDelivered: false,
                sessionID: sessionIDToSave
            )
            self.transcriptHistory.append(transcript)
            
            let localNodeID = NodeIdentity.shared.nodeID
            
            // Enqueue in persistent store-and-forward queue with WAITING_FOR_ACK / QUEUED state
            _ = SwiftDataService.shared.enqueuePendingMessage(
                messageID: sdTranscript.id,
                originID: localNodeID,
                destinationID: "BROADCAST",
                recipientName: "Broadcast",
                senderName: finalSpeaker,
                text: "[\(channel)] \(textToSave)",
                channel: channel
            )
            
            // Broadcast VoiceTranscript payload over P2P mesh network if connected
            let netMessage = Message(
                id: sdTranscript.id,
                originID: localNodeID,
                destinationID: "BROADCAST",
                senderID: localNodeID,
                senderName: finalSpeaker,
                channelID: channel,
                text: "[\(channel)] \(textToSave)",
                timestamp: Date(),
                hopsCount: 0,
                type: .transcript,
                sessionID: sessionIDToSave
            )
            
            self.currentSessionID = nil


            
            let encodedBytes = (try? JSONEncoder().encode(netMessage))?.count ?? 0
            AppLogger.audio.info("""
            [PINGLY_VOICE_TX]
            transcriptID=\(sdTranscript.id.uuidString)
            channel=\(channel)
            sender=\(finalSpeaker)
            destination=\(channel)
            textLength=\(textToSave.count)
            encodedBytes=\(encodedBytes)
            """)
            
            if isConnected {
                MultipeerService.shared.broadcast(message: netMessage)
                SwiftDataService.shared.updatePendingMessageStatus(messageID: sdTranscript.id, status: .waitingForACK)
                AppLogger.audio.info("Saved & broadcasted VoiceTranscript \(sdTranscript.id) on \(channel) (waiting for ACK).")
            } else {
                AppLogger.audio.info("Saved offline VoiceTranscript \(sdTranscript.id) on \(channel) to pending store-and-forward queue.")
            }
            
            NotificationCenter.default.post(name: .didSaveVoiceTranscript, object: nil)
        }
    }




    
    /// Manually injects a voice transcript (e.g. from received network framing packet or test broadcast).
    func addTranscript(speakerName: String, text: String, channel: String = "CH-1 EMERGENCY") {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            let transcript = VoiceTranscript(speakerName: speakerName, text: text, channel: channel)
            self.transcriptHistory.append(transcript)
            _ = SwiftDataService.shared.saveVoiceTranscript(speakerName: speakerName, text: text, channel: channel)
        }
    }


    
    /// Clears transcript history log.
    func clearHistory() {
        DispatchQueue.main.async {
            self.transcriptHistory.removeAll()
        }
    }
}
