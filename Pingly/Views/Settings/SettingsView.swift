//
//  SettingsView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Settings & Emergency SOS Profile View
struct SettingsView: View {
    @StateObject var viewModel: SettingsViewModel
    
    var body: some View {
        NavigationStack {
            ZStack {
                Constants.UI.Colors.backgroundDark
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Profile Identity Section
                        profileSection
                        
                        // Default Emergency Status
                        statusSection
                        
                        // Hardware Radios & Battery Optimization
                        radioSettingsSection
                        
                        // About & Version Info
                        aboutSection
                    }
                    .padding()
                }
            }
            .navigationTitle("Emergency Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Constants.UI.Colors.backgroundDark, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
    
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("OFF-GRID NODE IDENTITY", systemImage: "person.crop.circle.badge.checkmark")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Constants.UI.Colors.primaryAccent)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Device / Survivor Handle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Constants.UI.Colors.textSecondary)
                
                HStack {
                    TextField("Enter callsign", text: $viewModel.userHandle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Constants.UI.Colors.textPrimary)
                    
                    Button("Save") {
                        viewModel.applySettings()
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Constants.UI.Colors.primaryAccent)
                }
                .padding(10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .glassCardStyle()
    }
    
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("DEFAULT EMERGENCY CATEGORY", systemImage: "shield.trianglebadge.exclamationmark")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Constants.UI.Colors.warningOrange)
            
            Picker("Status", selection: $viewModel.selectedEmergencyStatus) {
                ForEach(EmergencyStatus.allCases) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .pickerStyle(.menu)
            .tint(Constants.UI.Colors.warningOrange)
        }
        .glassCardStyle()
    }
    
    private var radioSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MESH PROTOCOLS & BATTERY", systemImage: "bolt.batteryblock.fill")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Constants.UI.Colors.textSecondary)
            
            Toggle(isOn: $viewModel.isLowPowerModeEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Low Power BLE Beacon Mode")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Constants.UI.Colors.textPrimary)
                    Text("Reduces BLE scan frequency to save battery on long mountain treks.")
                        .font(.system(size: 12))
                        .foregroundColor(Constants.UI.Colors.textMuted)
                }
            }
            .tint(Constants.UI.Colors.primaryAccent)
        }
        .glassCardStyle()
    }
    
    private var aboutSection: some View {
        VStack(spacing: 8) {
            Text("Pingly Mesh v\(Constants.App.version) (\(Constants.App.build))")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Constants.UI.Colors.textSecondary)
            Text("Infrastructure-Independent Off-Grid Emergency Communication System")
                .font(.system(size: 11))
                .foregroundColor(Constants.UI.Colors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}
