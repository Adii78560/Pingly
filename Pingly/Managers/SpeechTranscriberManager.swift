//
//  SpeechTranscriberManager.swift
//  Pingly
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
    
    init(id: UUID = UUID(), speakerName: String, text: String, channel: String = "CH-1 EMERGENCY", timestamp: Date = Date()) {
        self.id = id
        self.speakerName = speakerName
        self.text = text
        self.channel = channel
        self.timestamp = timestamp
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
    
    // MARK: - Public Control API
    
    /// Starts live speech-to-text transcription for active speaker.
    func startTranscribing(speakerName: String, channel: String = "CH-1 EMERGENCY") {
        guard !isTranscribing else { return }
        self.activeSpeakerName = speakerName
        self.activeChannel = channel
        self.currentTranscriptText = ""
        
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
                let text = result.bestTranscription.formattedString
                AppLogger.audio.info("SFSpeechRecognitionTask text: \"\(text)\" (isFinal: \(result.isFinal))")
                DispatchQueue.main.async {
                    self.currentTranscriptText = text
                    
                    // Refine last logged transcript item if final recognition arrives after audio release
                    if result.isFinal, !text.isEmpty {
                        if let lastIndex = self.transcriptHistory.indices.last,
                           self.transcriptHistory[lastIndex].speakerName == self.activeSpeakerName {
                            let existing = self.transcriptHistory[lastIndex]
                            self.transcriptHistory[lastIndex] = VoiceTranscript(
                                id: existing.id,
                                speakerName: existing.speakerName,
                                text: text,
                                channel: existing.channel,
                                timestamp: existing.timestamp
                            )
                            AppLogger.audio.info("Updated final VoiceTranscript text: \"\(text)\"")
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
        
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        
        let finalSpeaker = activeSpeakerName
        let channel = activeChannel
        let rawText = currentTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let textToSave: String
        if !rawText.isEmpty {
            textToSave = rawText
        } else {
            textToSave = "Voice call broadcast recorded"
        }
        
        DispatchQueue.main.async {
            self.isTranscribing = false
            self.currentTranscriptText = ""
            
            let transcript = VoiceTranscript(speakerName: finalSpeaker, text: textToSave, channel: channel)
            self.transcriptHistory.append(transcript)
            
            // Persist transcript to SwiftData local storage
            _ = SwiftDataService.shared.saveVoiceTranscript(speakerName: finalSpeaker, text: textToSave, channel: channel)
            AppLogger.audio.info("Saved VoiceTranscript from \(finalSpeaker) on \(channel): \"\(textToSave)\"")
        }
        
        recognitionRequest = nil
        recognitionTask = nil
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
