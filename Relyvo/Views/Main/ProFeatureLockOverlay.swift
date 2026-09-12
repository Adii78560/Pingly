//
//  ProFeatureLockOverlay.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 05/09/26.
//

import SwiftUI

/// Premium Glassmorphic Lock Overlay for Pro-Gated Features
public struct ProFeatureLockOverlay: View {
    public let feature: RelyvoFeature
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var featureAccessManager = FeatureAccessManager.shared
    
    public init(feature: RelyvoFeature) {
        self.feature = feature
    }
    
    public var body: some View {
        ZStack {
            // Blurred Glass Background
            Color(UIColor.systemBackground).opacity(0.82)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Animated Lock Badge
                ZStack {
                    Circle()
                        .fill(AppTheme.primaryGradient)
                        .frame(width: 80, height: 80)
                        .shadow(color: AppTheme.hotMagenta.opacity(0.4), radius: 14, x: 0, y: 6)
                    
                    Image(systemName: "lock.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                }
                
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text(feature.title)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundColor(.primary)
                        
                        Text("PRO")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(AppTheme.hotMagenta))
                    }
                    
                    Text(feature.paywallDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                
                VStack(spacing: 12) {
                    // Unlock CTA Button
                    Button {
                        HapticsManager.shared.mediumImpact()
                        featureAccessManager.presentPaywall(for: feature)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text("Unlock with Relyvo Pro")
                                .font(.headline.weight(.bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: 280)
                        .frame(height: 50)
                        .background(AppTheme.primaryGradient)
                        .cornerRadius(14)
                        .shadow(color: AppTheme.hotMagenta.opacity(0.35), radius: 8, x: 0, y: 4)
                    }
                    
                    // Restore Purchases Link
                    Button {
                        Task {
                            HapticsManager.shared.lightImpact()
                            _ = await subscriptionManager.restorePurchases()
                        }
                    } label: {
                        if subscriptionManager.isRestoring {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Restore Purchases")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(subscriptionManager.isRestoring)
                }
                .padding(.top, 8)
                
                Text("📍 Radar and Emergency SOS remain 100% free.")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.8))
                    .padding(.top, 4)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(UIColor.secondarySystemGroupedBackground).opacity(0.95))
                    .shadow(color: Color.black.opacity(0.12), radius: 20, x: 0, y: 10)
            )
            .padding(.horizontal, 24)
        }
    }
}
