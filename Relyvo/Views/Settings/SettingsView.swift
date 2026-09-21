//
//  SettingsView.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/08/26.
//

import SwiftUI
import CoreLocation
import StoreKit
import RevenueCat
import RevenueCatUI

/// Native Apple iOS Settings View conforming to HIG & GDPR Privacy Controls
struct SettingsView: View {
    @StateObject var viewModel: SettingsViewModel
    @StateObject private var swiftDataService = SwiftDataService.shared
    @StateObject private var cloudSyncService = CloudSyncService.shared
    @StateObject private var locationService = LocationService.shared
    @StateObject private var dataExportService = DataExportService.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    @State private var showLogoutConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    @State private var showPaywallSheet = false
    @State private var showManageSubscriptionsSheet = false
    @State private var showRestoreAlert = false
    @State private var restoreAlertTitle = ""
    @State private var restoreAlertMessage = ""
    
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
    
    private func formattedDate(_ date: Date?) -> String {
        guard let date = date else { return "N/A" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                identitySection
                subscriptionSection
                hardwareRadiosSection
                privacyAndLegalSection
                dataManagementSection
                storageAndSyncSection
                accountControlsSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .sheet(isPresented: $showPaywallSheet) {
                SubscriptionPaywallView()
            }
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptionsSheet)
            .alert(restoreAlertTitle, isPresented: $showRestoreAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(restoreAlertMessage)
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
    
    // MARK: - 1. Identity & Profile Section
    
    private var identitySection: some View {
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
                        Text("Relyvo ID: \(username)")
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
    }
    
    // MARK: - 2. Subscription Section
    
    private var subscriptionSection: some View {
        Section {
            HStack(spacing: 14) {
                SettingsIconBadge(systemName: "crown.fill", backgroundColor: AppTheme.hotMagenta)
                
                VStack(alignment: .leading, spacing: 2) {
                    switch subscriptionManager.status {
                    case .activeAnnual(let expirationDate, _, let isTrial):
                        Text("Relyvo Pro")
                            .font(.body.weight(.semibold))
                        if isTrial {
                            Text("Free Trial Active • Renews \(formattedDate(expirationDate))")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else if let exp = expirationDate {
                            Text("Active • Renews \(formattedDate(exp))")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Text("Active (Annual Plan)")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    case .activeLifetime:
                        Text("Relyvo Forever")
                            .font(.body.weight(.semibold))
                        Text("Active (Lifetime Purchase)")
                            .font(.caption)
                            .foregroundColor(.green)
                    case .inGracePeriod(let expirationDate):
                        Text("Relyvo Pro")
                            .font(.body.weight(.semibold))
                        Text("Grace Period • Expires \(formattedDate(expirationDate))")
                            .font(.caption)
                            .foregroundColor(.orange)
                    case .billingIssue:
                        Text("Relyvo Pro")
                            .font(.body.weight(.semibold))
                        Text("Billing issue • Action required on Apple ID")
                            .font(.caption)
                            .foregroundColor(.red)
                    case .expired(let expirationDate):
                        Text("Relyvo Pro")
                            .font(.body.weight(.semibold))
                        Text("Expired on \(formattedDate(expirationDate))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .loading:
                        Text("Relyvo Pro")
                            .font(.body.weight(.semibold))
                        Text("Checking subscription status...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .notSubscribed, .unknown:
                        Text("Relyvo Pro")
                            .font(.body.weight(.semibold))
                        Text("Not subscribed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if subscriptionManager.isPro {
                    Text(subscriptionManager.status.isLifetime ? "LIFETIME" : "PRO")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(subscriptionManager.status.isLifetime ? Color.indigo : AppTheme.hotMagenta))
                }
            }
            .padding(.vertical, 2)
            
            switch subscriptionManager.status {
            case .notSubscribed, .unknown:
                Button(action: {
                    HapticsManager.shared.lightImpact()
                    showPaywallSheet = true
                }) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundColor(AppTheme.hotMagenta)
                        Text("Upgrade to Relyvo Pro")
                            .font(.body.weight(.semibold))
                            .foregroundColor(AppTheme.hotMagenta)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                    }
                }
            case .expired:
                Button(action: {
                    HapticsManager.shared.lightImpact()
                    showPaywallSheet = true
                }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(AppTheme.hotMagenta)
                        Text("Resubscribe to Relyvo Pro")
                            .font(.body.weight(.semibold))
                            .foregroundColor(AppTheme.hotMagenta)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                    }
                }
            case .activeAnnual, .inGracePeriod, .billingIssue:
                Button(action: {
                    HapticsManager.shared.lightImpact()
                    showManageSubscriptionsSheet = true
                }) {
                    HStack {
                        Image(systemName: "gearshape.2.fill")
                            .foregroundColor(.blue)
                        Text("Manage Subscription")
                            .font(.body)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                    }
                }
            case .activeLifetime, .loading:
                EmptyView()
            }
            
            Button(action: {
                Task {
                    HapticsManager.shared.mediumImpact()
                    let outcome = await subscriptionManager.restorePurchases()
                    switch outcome {
                    case .restored:
                        restoreAlertTitle = "Purchases Restored"
                        restoreAlertMessage = "Your Relyvo Pro purchase has been restored."
                    case .noActiveEntitlements:
                        restoreAlertTitle = "No Purchases Found"
                        restoreAlertMessage = "No active Relyvo Pro purchase was found."
                    case .failed(let msg):
                        restoreAlertTitle = "Restore Failed"
                        restoreAlertMessage = msg
                    }
                    showRestoreAlert = true
                }
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundColor(.teal)
                    Text(subscriptionManager.isRestoring ? "Restoring Purchases..." : "Restore Purchases")
                        .font(.body)
                        .foregroundColor(.primary)
                    Spacer()
                    if subscriptionManager.isRestoring {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(subscriptionManager.isRestoring)
        } header: {
            Text("Subscription")
        } footer: {
            Text("Relyvo Pro unlocks unlimited encrypted mesh channels, high-fidelity audio history, and live directional radar.")
        }
    }
    
    
    
    // MARK: - 4. Hardware Radios Section
    
    private var hardwareRadiosSection: some View {
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
                Text("Multipeer Wi-Direct")
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
    }
    
    
    
    // MARK: - 6. Privacy & Legal Section
    
    private var privacyAndLegalSection: some View {
        Section {
            Link(destination: Constants.Subscriptions.privacyPolicyURL) {
                HStack {
                    SettingsIconBadge(systemName: "hand.raised.fill", backgroundColor: .blue)
                    Text("Privacy Policy")
                        .font(.body)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
            }
            
            Link(destination: Constants.Subscriptions.termsOfServiceURL) {
                HStack {
                    SettingsIconBadge(systemName: "doc.plaintext.fill", backgroundColor: .indigo)
                    Text("Terms of Use (EULA)")
                        .font(.body)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Legal & Privacy")
        }
    }
    
    // MARK: - 7. Data Management & Controls Section
    
    private var dataManagementSection: some View {
        Section {
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
            Text("Relyvo accesses hardware GPS coordinates strictly when requested for off-grid SOS drops and direct peer location sharing. Zero location or personal data is shared with 3rd-party ad networks.")
        }
    }
    
    // MARK: - 8. SwiftData Storage & Cloud Sync Section
    
    private var storageAndSyncSection: some View {
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
    }
    
    // MARK: - 9. Account Controls Section
    
    private var accountControlsSection: some View {
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
    }
    
    // MARK: - 10. About Section
    
    private var aboutSection: some View {
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
                Text("Relyvo • Off-Grid Walkie-Talkie & P2P")
                Text("Designed for emergency mesh communication.")
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
        }
    }
}
