//
//  PrivacyPolicyView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 13/08/26.
//

import SwiftUI

/// Native SwiftUI Privacy Policy View detailing off-grid P2P data handling, local storage rules, and GDPR rights
struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    
    // Privacy policy URL configuration (production URL to be configured before release)
    private let privacyPolicyURLString = "https://pingly.app/privacy"
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header Banner
                    HStack(spacing: 14) {
                        Image(systemName: "hand.raised.shield.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pingly Privacy Policy")
                                .font(.title2.bold())
                            Text("Privacy-first, off-grid communication")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.bottom, 8)
                    
                    Divider()
                    
                    // Section 1: Data Minimization & Collection
                    privacySection(
                        title: "1. Data Minimization & Collection",
                        icon: "shippingbox.fill",
                        color: .blue,
                        content: "Pingly collects only the minimal data required for off-grid peer-to-peer messaging and Apple Sign-In authorization. Zero 3rd-party advertising or analytics SDKs are integrated into Pingly."
                    )
                    
                    // Section 2: Off-Grid P2P Mesh Architecture
                    privacySection(
                        title: "2. Off-Grid P2P Mesh Architecture",
                        icon: "antenna.radiowaves.left.and.right",
                        color: .indigo,
                        content: "Walkie-talkie audio, text messages, and distress drops are transmitted directly between nearby devices over Multipeer Wi-Fi Direct and CoreBluetooth BLE mesh with P2P TLS encryption. Zero messages are routed through ad servers."
                    )
                    
                    // Section 3: Location Privacy
                    privacySection(
                        title: "3. Location Privacy",
                        icon: "location.circle.fill",
                        color: .green,
                        content: "GPS coordinates are accessed strictly when you explicitly trigger distress drops or share location in chat. Location access can be toggled off at any time in Settings. Zero location data is continuously tracked or sold."
                    )
                    
                    // Section 4: Voice Recordings & Transcripts
                    privacySection(
                        title: "4. Voice & Walkie-Talkie Audio",
                        icon: "waveform",
                        color: .orange,
                        content: "Push-To-Talk voice audio is streamed live over P2P RAM buffers using the Opus codec and is immediately discarded after playback. On-device speech recognition runs locally via Apple Speech framework."
                    )
                    
                    // Section 5: GDPR User Rights
                    privacySection(
                        title: "5. Your Rights Under GDPR",
                        icon: "checkmark.shield.fill",
                        color: .teal,
                        content: "You have the right to Access, Rectify, Export ('Request My Data'), and Permanently Erase ('Delete Account') all your personal data at any time directly within Pingly Settings."
                    )
                    
                    // Section 6: Web Privacy Policy Link
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Web Privacy Policy")
                            .font(.headline)
                        
                        Text("For complete legal disclosures, please review our full web privacy policy:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Button(action: {
                            if let url = URL(string: privacyPolicyURLString) {
                                UIApplication.shared.open(url)
                            }
                        }) {
                            HStack {
                                Image(systemName: "safari.fill")
                                Text("Open pingly.app/privacy")
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.blue)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .padding()
            }
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
    
    private func privacySection(title: String, icon: String, color: Color, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.headline)
                Text(title)
                    .font(.headline)
            }
            Text(content)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    PrivacyPolicyView()
}
