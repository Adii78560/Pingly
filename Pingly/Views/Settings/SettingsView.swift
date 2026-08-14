//
//  SettingsView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 13/08/26.
//

import SwiftUI
import CoreLocation

/// Native Apple iOS Settings View conforming to HIG & GDPR Privacy Controls
struct SettingsView: View {
    @StateObject var viewModel: SettingsViewModel
    @StateObject private var swiftDataService = SwiftDataService.shared
    @StateObject private var cloudSyncService = CloudSyncService.shared
    @StateObject private var locationService = LocationService.shared
    @StateObject private var attManager = ATTManager.shared
    @StateObject private var dataExportService = DataExportService.shared
    
    @State private var showLogoutConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    @State private var showPrivacyPolicySheet = false
    
    private var locationPermissionString: String {
        switch locationService.authorizationStatus {
        case .authorizedWhenInUse: return "Authorized When In Use"
        case .authorizedAlways: return "Authorized Always"
        case .denied: return "Denied (Tap to Open Settings)"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Determined"
        @unknown default: return "Unknown"
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // Section 1: Profile & Node Identity
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.primaryGradient)
                                .frame(width: 54, height: 54)
                                .shadow(color: AppTheme.hotMagenta.opacity(0.35), radius: 8, x: 0, y: 3)
                            Text(viewModel.userHandle.initials)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.userHandle)
                                .font(.headline)
                            if let username = AppleSignInManager.shared.username {
                                Text("Relayn ID: \(username)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(AppTheme.tintColor)
                            } else {
                                Text("Off-Grid P2P Mesh Node")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    
                    HStack {
                        SettingsIconBadge(systemName: "person.crop.circle", backgroundColor: AppTheme.tintColor)
                        Text("Broadcast Handle")
                            .font(.body)
                        Spacer()
                        TextField("Callsign", text: $viewModel.userHandle)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .onSubmit {
                                IdentityManager.shared.updateDisplayName(viewModel.userHandle)
                                viewModel.applySettings()
                                HapticsManager.shared.successFeedback()
                            }
                    }
                    
                    // Stable Identifiers Info
                    HStack {
                        SettingsIconBadge(systemName: "number.square.fill", backgroundColor: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Account ID")
                                .font(.body)
                            Text(IdentityManager.shared.accountID?.uuidString ?? "Apple Auth Active")
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    HStack {
                        SettingsIconBadge(systemName: "key.fill", backgroundColor: .indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keychain Device ID")
                                .font(.body)
                            Text(IdentityManager.shared.deviceID.uuidString)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                } header: {
                    Text("Identity & Profile")
                } footer: {
                    Text("Changing your Broadcast Handle updates only your display name. Your Account ID and Keychain Device ID remain permanently stable across name changes, logouts, and reinstalls.")
                }

                
                // Section 2: Emergency Profile
                Section {
                    HStack {
                        SettingsIconBadge(systemName: "checkmark.shield.fill", backgroundColor: .orange)
                        Picker("Default Status", selection: $viewModel.selectedEmergencyStatus) {
                            ForEach(EmergencyStatus.allCases) { status in
                                Text(status.rawValue).tag(status)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("Distress Profile")
                } footer: {
                    Text("Default status broadcasted to nearby emergency nodes when scanning.")
                }
                
                // Section 3: Hardware Radios
                Section {
                    Toggle(isOn: $viewModel.isLowPowerModeEnabled) {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "battery.100.bolt", backgroundColor: .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Low Power Mode")
                                    .font(.body)
                                Text("Reduce BLE scan frequency to preserve battery")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .tint(.green)
                    
                    HStack {
                        SettingsIconBadge(systemName: "antenna.radiowaves.left.and.right", backgroundColor: .indigo)
                        Text("Multipeer Wi-Fi Direct")
                        Spacer()
                        Text("Active")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        SettingsIconBadge(systemName: "bolt.horizontal.fill", backgroundColor: .blue)
                        Text("CoreBluetooth BLE Mesh")
                        Spacer()
                        Text("Active")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Hardware Radios")
                }
                
                // Section 4: Privacy, App Tracking Transparency & Offline Location
                Section {
                    // iOS Settings Link
                    Button(action: {
                        HapticsManager.shared.lightImpact()
                        locationService.openAppSettings()
                    }) {
                        HStack {
                            SettingsIconBadge(systemName: "gear", backgroundColor: .gray)
                            Text("Open iOS System Settings")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // Section: Mesh Diagnostics & Notification System
                Section("Diagnostics & Delivery Status") {
                    NavigationLink(destination: MeshDiagnosticsView()) {
                        HStack {
                            SettingsIconBadge(systemName: "bell.badge.waveform.fill", backgroundColor: AppTheme.tintColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Mesh Diagnostics & Notification Log")
                                    .font(.body)
                                Text("Inspect active peers, delivery ACKs & event deduplication")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                Section {
                    // Privacy Policy Sheet
                    Button(action: {
                        HapticsManager.shared.lightImpact()
                        showPrivacyPolicySheet = true
                    }) {
                        HStack {
                            SettingsIconBadge(systemName: "doc.text.fill", backgroundColor: .blue)
                            Text("Privacy Policy")
                                .font(.body)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Request/Export My Data (GDPR)
                    Button(action: {
                        HapticsManager.shared.mediumImpact()
                        dataExportService.exportUserData()
                    }) {
                        HStack {
                            SettingsIconBadge(systemName: "square.and.arrow.up.fill", backgroundColor: .teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Request My Data (GDPR Export)")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text("Export personal profile, messages & transcripts as JSON")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    
                    // GPS Permission
                    HStack {
                        SettingsIconBadge(systemName: "location.circle.fill", backgroundColor: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("GPS Location Permission")
                                .font(.body)
                            Text(locationPermissionString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    // Offline Location Toggle
                    Toggle(isOn: Binding(
                        get: { locationService.isSharingLocation },
                        set: { newValue in
                            HapticsManager.shared.lightImpact()
                            if newValue {
                                locationService.startSharingLocation()
                            } else {
                                locationService.stopSharingLocation()
                            }
                        }
                    )) {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "location.fill", backgroundColor: .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Offline GPS Location Sharing")
                                    .font(.body)
                                Text("Share offline coordinates over P2P mesh network")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .tint(.orange)
                    
                    // ATT Tracking Status
                    HStack {
                        SettingsIconBadge(systemName: "hand.raised.fill", backgroundColor: .purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("App Tracking Transparency")
                                .font(.body)
                            Text("P2P mesh uses zero 3rd-party ad tracking")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(attManager.statusDescription)
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                    }
                    
                    // iOS Settings Link
                    Button(action: {
                        HapticsManager.shared.lightImpact()
                        locationService.openAppSettings()
                    }) {
                        HStack {
                            Image(systemName: "gearshape.fill")
                            Text("Manage Privacy & Location in System Settings")
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(.blue)
                    }
                } header: {
                    Text("Privacy & Data Controls")
                } footer: {
                    Text("Pingly accesses hardware GPS coordinates strictly when requested for off-grid SOS drops and direct peer location sharing. Zero location or personal data is shared with 3rd-party ad networks.")
                }

                // Section 5: SwiftData Local Storage & Cloud Sync
                Section {
                    HStack {
                        SettingsIconBadge(systemName: "icloud.and.arrow.up.fill", backgroundColor: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cloud Sync Status")
                                .font(.body)
                            Text(cloudSyncService.syncStatusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack {
                        SettingsIconBadge(systemName: "externaldrive.fill", backgroundColor: .orange)
                        Text("Unsynced Off-Grid Items")
                            .font(.body)
                        Spacer()
                        Text("\(swiftDataService.totalUnsyncedCount) pending")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: {
                        cloudSyncService.syncPendingDataToCloud()
                    }) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(cloudSyncService.isSyncing ? "Syncing..." : "Sync SwiftData to Cloud Now")
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(cloudSyncService.isInternetAvailable ? .orange : .gray)
                    }
                    .disabled(!cloudSyncService.isInternetAvailable || cloudSyncService.isSyncing)
                } header: {
                    Text("SwiftData Storage & Cloud Sync")
                } footer: {
                    Text("Off-grid transcripts and messages are saved in SwiftData local storage. When internet is available, data automatically syncs to your logged-in device cloud account.")
                }

                // Section 6: Account & Authentication Log Out & GDPR Deletion
                Section {
                    Button(role: .destructive, action: {
                        HapticsManager.shared.warningFeedback()
                        showLogoutConfirmation = true
                    }) {
                        HStack {
                            SettingsIconBadge(systemName: "rectangle.portrait.and.arrow.right.fill", backgroundColor: .orange)
                            Text("Log Out")
                                .font(.body.weight(.medium))
                                .foregroundColor(.orange)
                            Spacer()
                        }
                    }
                    
                    Button(role: .destructive, action: {
                        HapticsManager.shared.warningFeedback()
                        showDeleteAccountConfirmation = true
                    }) {
                        HStack {
                            SettingsIconBadge(systemName: "trash.fill", backgroundColor: .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Delete Account")
                                    .font(.body.weight(.bold))
                                    .foregroundColor(.red)
                                Text("Permanently delete account, messages & cloud data")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                } header: {
                    Text("Account Controls")
                } footer: {
                    Text("Deleting your account permanently purges all local SwiftData messages, transcripts, profile data, and backend records.")
                }

                // Section 7: App Information
                Section {
                    HStack {
                        SettingsIconBadge(systemName: "info.circle.fill", backgroundColor: .gray)
                        Text("Version")
                        Spacer()
                        Text("\(Constants.App.version) (\(Constants.App.build))")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        SettingsIconBadge(systemName: "checkmark.shield.fill", backgroundColor: .teal)
                        Text("Security & Encryption")
                        Spacer()
                        Text("Apple P2P TLS & SwiftData")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                } footer: {
                    VStack(spacing: 4) {
                        Text("RadioFy / Pingly • Off-Grid Walkie-Talkie & P2P")
                        Text("Designed for emergency mesh communication.")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .sheet(isPresented: $showPrivacyPolicySheet) {
                PrivacyPolicyView()
            }
            .alert("Log Out", isPresented: $showLogoutConfirmation) {
                Button("Log Out", role: .destructive) {
                    HapticsManager.shared.heavyImpact()
                    AppleSignInManager.shared.signOut()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to log out?")
            }
            .alert("Delete Account & All Personal Data?", isPresented: $showDeleteAccountConfirmation) {
                Button("Delete Account", role: .destructive) {
                    HapticsManager.shared.heavyImpact()
                    AppleSignInManager.shared.deleteAccountAndSignOut { }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action is permanent and cannot be undone. All your off-grid transcripts, chat history, profile info, and cloud records will be permanently erased.")
            }
        }
    }
}
