//
//  FeatureAccessManager.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 05/09/26.
//

import Foundation
import SwiftUI
import Combine

// MARK: - Relyvo Features

/// Domain enumeration of Relyvo application features and their access tiers
public enum RelyvoFeature: String, CaseIterable, Identifiable, Sendable {
    case radar
    case walkieTalkie
    case messaging
    case createChannel
    
    public var id: String { rawValue }
    
    /// Indicates whether the feature requires an active Relyvo Pro entitlement
    public var isProRequired: Bool {
        switch self {
        case .radar:
            return false // Radar is free for all users
        case .walkieTalkie, .messaging, .createChannel:
            return true // Pro features
        }
    }
    
    /// User-facing display title for the feature
    public var title: String {
        switch self {
        case .radar:
            return "Mesh Radar"
        case .walkieTalkie:
            return "Walkie-Talkie"
        case .messaging:
            return "Offline Messages"
        case .createChannel:
            return "Custom Channels"
        }
    }
    
    /// Icon system name
    public var iconName: String {
        switch self {
        case .radar:
            return "dot.radiowaves.left.and.right"
        case .walkieTalkie:
            return "waveform.and.mic"
        case .messaging:
            return "message.fill"
        case .createChannel:
            return "plus.circle.fill"
        }
    }
    
    /// Contextual paywall hero title when gating this feature
    public var paywallTitle: String {
        switch self {
        case .radar:
            return "Unlock Relyvo Pro"
        case .walkieTalkie:
            return "Unlock Walkie-Talkie"
        case .messaging:
            return "Unlock Offline Messaging"
        case .createChannel:
            return "Unlock Custom Channels"
        }
    }
    
    /// Contextual paywall explanation text
    public var paywallDescription: String {
        switch self {
        case .radar:
            return "Supercharge your off-grid capabilities with private mesh channels and real-time audio."
        case .walkieTalkie:
            return "Relyvo Pro unlocks real-time push-to-talk voice transmissions and high-fidelity 30-day audio history."
        case .messaging:
            return "Relyvo Pro unlocks encrypted peer-to-peer messaging and offline transcript storage."
        case .createChannel:
            return "Relyvo Pro unlocks unlimited custom sub-channels for private team coordination."
        }
    }
}

// MARK: - Central Feature Access Manager

/// Centralized access controller enforcing feature gating based on authoritative RevenueCat Pro entitlement
@MainActor
public final class FeatureAccessManager: ObservableObject {
    
    // MARK: - Singleton
    
    public static let shared = FeatureAccessManager()
    
    // MARK: - Published State
    
    @Published public var activePaywallFeature: RelyvoFeature? = nil
    @Published public var showPaywall: Bool = false
    
    // MARK: - Dependencies
    
    private let subscriptionManager: SubscriptionManager
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    @MainActor
    public init(subscriptionManager: SubscriptionManager = .shared) {
        self.subscriptionManager = subscriptionManager
        
        // Forward changes from SubscriptionManager so UI re-evaluates automatically
        subscriptionManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Access Policy API
    
    /// Fast synchronous check to determine whether a feature is unlocked
    public func canAccess(_ feature: RelyvoFeature) -> Bool {
        if !feature.isProRequired {
            return true // Free feature (e.g. Radar)
        }
        return subscriptionManager.isPro
    }
    
    /// Enforces feature access: Executes `onGranted` if unlocked, or presents Paywall for `feature` and executes `onDenied`
    @discardableResult
    public func requireAccess(
        to feature: RelyvoFeature,
        onGranted: () -> Void = {},
        onDenied: (() -> Void)? = nil
    ) -> Bool {
        if canAccess(feature) {
            onGranted()
            return true
        } else {
            HapticsManager.shared.warningFeedback()
            presentPaywall(for: feature)
            onDenied?()
            return false
        }
    }
    
    /// Opens the paywall sheet targeting a specific gated feature
    public func presentPaywall(for feature: RelyvoFeature) {
        self.activePaywallFeature = feature
        self.showPaywall = true
    }
    
    /// Dismisses the paywall sheet
    public func dismissPaywall() {
        self.showPaywall = false
        self.activePaywallFeature = nil
    }
}
