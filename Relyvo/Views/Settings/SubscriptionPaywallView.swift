//
//  SubscriptionPaywallView.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 11/09/26.
//

import SwiftUI
import RevenueCat

/// Custom native SwiftUI Paywall matching Relyvo brand aesthetics:
/// Top pill navigation, circular app icon, clean feature list, unified package card,
/// gradient CTA button, auto-renewal legal disclosure, and friendly alerts.
struct SubscriptionPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var featureAccessManager = FeatureAccessManager.shared
    
    @State private var selectedPackageID: String? = nil
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var shouldDismissOnAlertDismiss = false
    
    /// Optional contextual feature that triggered the paywall
    var feature: RelyvoFeature? = nil
    
    private var selectedPackage: SubscriptionPackage? {
        if let id = selectedPackageID {
            return subscriptionManager.availablePackages.first(where: { $0.id == id })
        }
        return subscriptionManager.annualPackage ?? subscriptionManager.availablePackages.first
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Adaptive Clean Background
                Constants.UI.Colors.primaryBackground
                    .ignoresSafeArea()
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // 1. Top Navigation Bar: BACK - App Icon - RESTORE
                        topBarSection
                            .padding(.top, 4)
                        
                        // 2. Big Bold App Title & Divider
                        headerSection
                            .padding(.top, 6)
                        
                        // 3. Feature Highlights
                        featuresListSection
                        
                        // 4. Combined Package Selector Box
                        packageSelectorBox
                            .padding(.top, 4)
                        
                        // 5. Continue CTA Button
                        ctaButtonSection
                        
                        // 6. Bottom Legal Disclosure & URLs
                        legalAndDisclosureSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .navigationBarHidden(true)
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) {
                    if shouldDismissOnAlertDismiss {
                        featureAccessManager.dismissPaywall()
                        dismiss()
                    }
                }
            } message: {
                Text(alertMessage)
            }
            .onAppear {
                setupInitialSelection()
                if subscriptionManager.availablePackages.isEmpty {
                    Task {
                        _ = try? await subscriptionManager.fetchOfferings()
                        setupInitialSelection()
                    }
                }
            }
            .onChange(of: subscriptionManager.availablePackages.count) { _, _ in
                setupInitialSelection()
            }
            .onChange(of: subscriptionManager.isPro) { _, isPro in
                if isPro {
                    featureAccessManager.dismissPaywall()
                }
            }
        }
    }
    
    // MARK: - 1. Top Bar Section (BACK - App Icon - RESTORE)
    
    private var topBarSection: some View {
        HStack {
            // BACK Pill Button
            Button(action: {
                HapticsManager.shared.lightImpact()
                dismiss()
            }) {
                Text("BACK")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(Capsule())
            }
            .accessibilityLabel("Go Back")
            
            Spacer()
            
            // App Icon Circle
            appIconView
            
            Spacer()
            
            // RESTORE Pill Button
            Button(action: {
                HapticsManager.shared.lightImpact()
                performRestore()
            }) {
                if subscriptionManager.isRestoring {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color(UIColor.systemGray5))
                        .clipShape(Capsule())
                } else {
                    Text("RESTORE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color(UIColor.systemGray5))
                        .clipShape(Capsule())
                }
            }
            .disabled(subscriptionManager.isRestoring || subscriptionManager.isPurchasing)
            .accessibilityLabel("Restore Purchases")
        }
        .padding(.top)
    }
    
    private var appIconView: some View {
        Group {
            if let img = UIImage(named: "AppLogo") ?? getAppIcon() {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 58, height: 58)
                    .clipShape(Circle())
                    .shadow(color: AppTheme.hotMagenta.opacity(0.35), radius: 8, x: 0, y: 4)
            } else {
                ZStack {
                    Circle()
                        .fill(AppTheme.primaryGradient)
                        .frame(width: 58, height: 58)
                    
                    Image(systemName: "message.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                }
                .shadow(color: AppTheme.hotMagenta.opacity(0.35), radius: 8, x: 0, y: 4)
            }
        }
    }
    
    private func getAppIcon() -> UIImage? {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
           let lastIcon = iconFiles.last {
            return UIImage(named: lastIcon)
        }
        return UIImage(named: "AppIcon")
    }
    
    // MARK: - 2. App Title Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Relyvo")
                .font(.system(size: 32, weight: .heavy, design: .default))
                .foregroundColor(.primary)
            
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }
    
    // MARK: - 3. Feature Highlights List
    
    private var featuresListSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(
                icon: "message.fill",
                title: "Offline Messaging",
                description: "Send messages without internet using nearby devices and Relyvo's mesh network."
            )
            
            featureRow(
                icon: "mic.fill",
                title: "Walkie-Talkie",
                description: "Talk in real time with nearby users, even when there's no cellular connection."
            )
            
            featureRow(
                icon: "antenna.radiowaves.left.and.right",
                title: "Offline Radar",
                description: "Discover nearby Relyvo users and see your local network come alive around you."
            )
            
            featureRow(
                icon: "location.north.line.fill",
                title: "Live Location",
                description: "Share your location directly with nearby friends without relying on mobile data."
            )
            
            featureRow(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Multi-Hop Network",
                description: "Messages can travel through other Relyvo users, reaching people beyond direct range."
            )
        }
    }
    
    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: 26, alignment: .center)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.primary)
                
                Text(description)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    // MARK: - 4. Combined Package Selector Box
    
    private var packageSelectorBox: some View {
        VStack(spacing: 0) {
            if subscriptionManager.isLoading && subscriptionManager.availablePackages.isEmpty {
                loadingPackagesSkeleton
            } else if subscriptionManager.availablePackages.isEmpty {
                emptyPackagesFallback
            } else {
                let packages = subscriptionManager.availablePackages
                ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                    packageRow(package)
                    
                    if index < packages.count - 1 {
                        Divider()
                            .padding(.horizontal, 14)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
    }
    
    private func packageRow(_ package: SubscriptionPackage) -> some View {
        let isSelected = selectedPackage?.id == package.id
        
        return Button(action: {
            HapticsManager.shared.lightImpact()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                selectedPackageID = package.id
            }
        }) {
            HStack(spacing: 12) {
                // Radio Circle
                ZStack {
                    Circle()
                        .stroke(isSelected ? AppTheme.tintColor : Color.secondary.opacity(0.35), lineWidth: 2)
                        .frame(width: 22, height: 22)
                    
                    if isSelected {
                        Circle()
                            .fill(AppTheme.primaryGradient)
                            .frame(width: 14, height: 14)
                    }
                }
                
                // Package Title and Badges
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(package.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                        
                        if package.isPopular {
                            Text("SAVE 60%")
                                .font(.system(size: 9.5, weight: .black))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue))
                        } else if package.isLifetime {
                            Text("ONE-TIME")
                                .font(.system(size: 9.5, weight: .black))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.indigo))
                        }
                    }
                    
                    if let trial = package.trialPeriodDescription {
                        Text(trial)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !package.subtitle.isEmpty {
                        Text(package.subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                Spacer(minLength: 8)
                
                // Price text (e.g. "$14.99/year" or "$39.99")
                Text(package.isLifetime ? package.localizedPrice : "\(package.localizedPrice)/\(package.periodDescription)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(package.title), \(package.localizedPrice). \(isSelected ? "Selected" : "Not selected")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
    
    private var loadingPackagesSkeleton: some View {
        VStack(spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                HStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 22, height: 22)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 100, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 140, height: 10)
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 70, height: 14)
                }
                .padding(14)
            }
        }
        .redacted(reason: .placeholder)
    }
    
    private var emptyPackagesFallback: some View {
        VStack(spacing: 6) {
            Text("Unable to load product pricing")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.primary)
            
            Button(action: {
                Task {
                    _ = try? await subscriptionManager.fetchOfferings()
                    setupInitialSelection()
                }
            }) {
                Text("Tap to Retry")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.tintColor)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 5. Continue CTA Button
    
    private var ctaButtonSection: some View {
        Button(action: {
            guard let package = selectedPackage else { return }
            HapticsManager.shared.mediumImpact()
            
            Task {
                let outcome = await subscriptionManager.purchase(package: package)
                switch outcome {
                case .success:
                    HapticsManager.shared.successFeedback()
                    alertTitle = Constants.Subscriptions.purchaseSuccessTitle
                    alertMessage = Constants.Subscriptions.purchaseSuccessMessage
                    shouldDismissOnAlertDismiss = true
                    showAlert = true
                case .pending:
                    alertTitle = Constants.Subscriptions.purchaseSuccessTitle
                    alertMessage = Constants.Subscriptions.purchaseSuccessMessage
                    shouldDismissOnAlertDismiss = true
                    showAlert = true
                case .cancelled:
                    // Normal cancellation - keep paywall open for retry
                    break
                case .error:
                    HapticsManager.shared.warningFeedback()
                    alertTitle = Constants.Subscriptions.purchaseFailedTitle
                    alertMessage = Constants.Subscriptions.purchaseFailedMessage
                    shouldDismissOnAlertDismiss = false
                    showAlert = true
                }
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.22, blue: 0.45),
                                Color(red: 1.0, green: 0.40, blue: 0.35)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: Color(red: 1.0, green: 0.25, blue: 0.45).opacity(0.35), radius: 8, x: 0, y: 4)
                
                if subscriptionManager.isPurchasing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.0)
                } else {
                    Text(ctaButtonTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(height: 52)
        }
        .disabled(selectedPackage == nil || subscriptionManager.isPurchasing || subscriptionManager.isRestoring)
        .opacity(selectedPackage == nil ? 0.6 : 1.0)
        .accessibilityLabel(ctaButtonTitle)
        .padding(.top, 2)
    }
    
    private var ctaButtonTitle: String {
        guard let package = selectedPackage else { return "Continue" }
        if package.hasFreeTrial {
            return "Start Free Trial"
        }
        return "Continue"
    }
    
    // MARK: - 6. Legal & Auto-Renewal Disclosures
    
    private var legalAndDisclosureSection: some View {
        VStack(spacing: 12) {
            // Auto-renewal disclosure text required by Apple App Store Guidelines
            Text("Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Your Apple ID account will be charged upon confirmation. You can manage and cancel your subscriptions in your App Store Account Settings.")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(Color.secondary.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
            
            // Privacy Policy & Terms of Service Links
            HStack(spacing: 24) {
                Button(action: {
                    openURL(Constants.Subscriptions.privacyPolicyURL)
                }) {
                    Text("Privacy policy")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Button(action: {
                    openURL(Constants.Subscriptions.termsOfServiceURL)
                }) {
                    Text("Terms of service")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
    
    // MARK: - Restore Purchases Action Helper
    
    private func performRestore() {
        Task {
            let outcome = await subscriptionManager.restorePurchases()
            switch outcome {
            case .restored:
                HapticsManager.shared.successFeedback()
                alertTitle = Constants.Subscriptions.restoreSuccessTitle
                alertMessage = Constants.Subscriptions.restoreSuccessMessage
                shouldDismissOnAlertDismiss = true
            case .noActiveEntitlements:
                alertTitle = Constants.Subscriptions.restoreNotFoundTitle
                alertMessage = Constants.Subscriptions.restoreNotFoundMessage
                shouldDismissOnAlertDismiss = false
            case .failed:
                alertTitle = Constants.Subscriptions.restoreFailedTitle
                alertMessage = Constants.Subscriptions.restoreFailedMessage
                shouldDismissOnAlertDismiss = false
            }
            showAlert = true
        }
    }
    
    // MARK: - Selection Setup Helper
    
    private func setupInitialSelection() {
        if selectedPackageID == nil {
            if let annual = subscriptionManager.annualPackage {
                selectedPackageID = annual.id
            } else if let lifetime = subscriptionManager.lifetimePackage {
                selectedPackageID = lifetime.id
            } else if let first = subscriptionManager.availablePackages.first {
                selectedPackageID = first.id
            }
        }
    }
}

