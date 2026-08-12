//
//  DataExportService.swift
//  Pingly
//
//  Created by Senior iOS Developer on 13/08/26.
//

import SwiftUI
import UIKit
import Combine
import os


struct GDPRDataExportBundle: Codable {
    let exportDate: Date
    let appVersion: String
    let userProfile: GDPRUserProfileExport?
    let chatMessages: [GDPRMessageExport]
    let voiceTranscripts: [GDPRTranscriptExport]
}

struct GDPRUserProfileExport: Codable {
    let appleUserID: String
    let pinglyUsername: String
    let displayName: String
    let email: String?
    let createdAt: Date
}

struct GDPRMessageExport: Codable {
    let id: UUID
    let senderName: String
    let channel: String
    let text: String
    let messageType: String
    let latitude: Double?
    let longitude: Double?
    let timestamp: Date
}

struct GDPRTranscriptExport: Codable {
    let id: UUID
    let speakerName: String
    let channel: String
    let text: String
    let timestamp: Date
}

/// Service providing automated GDPR Data Portability ("Export My Data")
@MainActor
final class DataExportService: ObservableObject {
    static let shared = DataExportService()
    
    @Published private(set) var isExporting: Bool = false
    
    private init() {}
    
    /// Generates structured JSON export bundle of user's personal data and opens native iOS Share Sheet
    func exportUserData() {
        guard !isExporting else { return }
        isExporting = true
        
        Task { @MainActor in
            let swiftData = SwiftDataService.shared
            
            // 1. Export User Profile
            var profileExport: GDPRUserProfileExport? = nil
            if let currentUserID = AppleSignInManager.shared.appleUserID,
               let profile = swiftData.fetchUserProfile(appleUserID: currentUserID) {
                profileExport = GDPRUserProfileExport(
                    appleUserID: profile.appleUserID,
                    pinglyUsername: profile.username,
                    displayName: profile.displayName,
                    email: profile.email,
                    createdAt: profile.createdAt
                )
            }
            
            // 2. Export Chat Messages
            let (unfilteredTranscripts, unfilteredMessages) = swiftData.fetchUnsyncedItems()
            let messageExports = unfilteredMessages.map {
                GDPRMessageExport(
                    id: $0.id,
                    senderName: $0.senderName,
                    channel: $0.channel,
                    text: $0.text,
                    messageType: "CHAT",
                    latitude: nil,
                    longitude: nil,
                    timestamp: $0.timestamp
                )
            }
            
            // 3. Export Transcripts
            let transcriptExports = unfilteredTranscripts.map {
                GDPRTranscriptExport(
                    id: $0.id,
                    speakerName: $0.speakerName,
                    channel: $0.channel,
                    text: $0.text,
                    timestamp: $0.timestamp
                )
            }
            
            let exportBundle = GDPRDataExportBundle(
                exportDate: Date(),
                appVersion: "1.0.0",
                userProfile: profileExport,
                chatMessages: messageExports,
                voiceTranscripts: transcriptExports
            )
            
            // 4. Encode to formatted JSON
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            
            guard let jsonData = try? encoder.encode(exportBundle) else {
                self.isExporting = false
                return
            }
            
            // 5. Save to temporary export file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Pingly_GDPR_Data_Export.json")
            try? jsonData.write(to: tempURL)
            
            self.isExporting = false
            
            // 6. Present native UIActivityViewController (Share Sheet)
            presentShareSheet(for: tempURL)
        }
    }
    
    private func presentShareSheet(for fileURL: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        
        let activityViewController = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        
        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = rootViewController.view
            popover.sourceRect = CGRect(x: rootViewController.view.bounds.midX, y: rootViewController.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        
        rootViewController.present(activityViewController, animated: true)
    }
}
