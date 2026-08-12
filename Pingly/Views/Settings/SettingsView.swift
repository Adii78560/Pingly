//
//  SettingsView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

////
//  SettingsView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Native Apple iOS Settings View conforming to HIG
struct SettingsView: View {
    @StateObject var viewModel: SettingsViewModel
    @StateObject private var swiftDataService = SwiftDataService.shared
    @StateObject private var cloudSyncService = CloudSyncService.shared
    @State private var showLogoutConfirmation = false
    
    var body: some View {


        NavigationStack {
            Form {
                // Section 1: Profile & Node Identity
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.15))
                                .frame(width: 54, height: 54)
                            Text(viewModel.userHandle.initials)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.orange)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.userHandle)
                                .font(.headline)
                            if let username = AppleSignInManager.shared.username {
                                Text("Pingly ID: \(username)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.orange)
                            } else {
                                Text("Off-Grid P2P Mesh Node")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                    }
                    .padding(.vertical, 4)
                    
                    HStack {
                        SettingsIconBadge(systemName: "person.crop.circle", backgroundColor: .orange)
                        Text("Broadcast Handle")
                            .font(.body)
                        Spacer()
                        TextField("Callsign", text: $viewModel.userHandle)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .onSubmit {
                                viewModel.applySettings()
                                HapticManager.successFeedback()
                            }
                    }
                } header: {
                    Text("Identity")
                }
                
                // Section 2: Emergency Category
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
                
                // Section 3: Radios & Battery Optimization
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
                
                // Section 4: SwiftData Local Storage & Cloud Sync
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

                // Section 5: Account & Authentication Log Out
                Section {
                    Button(role: .destructive, action: {
                        HapticsManager.shared.warningFeedback()
                        showLogoutConfirmation = true
                    }) {
                        HStack {
                            SettingsIconBadge(systemName: "rectangle.portrait.and.arrow.right.fill", backgroundColor: .red)
                            Text("Log Out")
                                .font(.body.weight(.medium))
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Logging out clears your active local session and requires re-authentication.")
                }

                // Section 6: App Information
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
            .alert("Log Out", isPresented: $showLogoutConfirmation) {
                Button("Log Out", role: .destructive) {
                    HapticsManager.shared.heavyImpact()
                    AppleSignInManager.shared.signOut()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to log out?")
            }
        }
    }
}





