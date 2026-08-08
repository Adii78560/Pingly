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
                            Text("Off-Grid P2P Mesh Node")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
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
                }
 header: {
                    Text("Identity")
                }
                
                // Section 2: Emergency Category
                Section {
                    HStack {
                        SettingsIconBadge(systemName: "exclamationmark.shield.fill", backgroundColor: .orange)
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
                
                // Section 4: App Information
                Section {
                    HStack {
                        SettingsIconBadge(systemName: "info.circle.fill", backgroundColor: .gray)
                        Text("Version")
                        Spacer()
                        Text("\(Constants.App.version) (\(Constants.App.build))")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        SettingsIconBadge(systemName: "shield.fill", backgroundColor: .teal)
                        Text("Security & Encryption")
                        Spacer()
                        Text("Apple P2P TLS")
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
        }
    }
}


