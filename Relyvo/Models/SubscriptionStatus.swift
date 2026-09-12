//
//  SubscriptionStatus.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 05/09/26.
//

import Foundation
import RevenueCat

// MARK: - Subscription Status

/// Authoritative domain representation of customer's active Relyvo subscription / lifetime status
public enum SubscriptionStatus: Equatable, Sendable {
    /// Subscription state is being initialized or refreshed from RevenueCat
    case loading
    
    /// User does not hold an active Relyvo Pro entitlement
    case notSubscribed
    
    /// User has an active recurring Annual subscription
    case activeAnnual(
        expirationDate: Date?,
        willRenew: Bool,
        isTrial: Bool
    )
    
    /// User owns a permanent, non-expiring Lifetime purchase (Relyvo Forever)
    case activeLifetime
    
    /// User is in Apple's billing grace period (retains access while Apple attempts collection)
    case inGracePeriod(expirationDate: Date?)
    
    /// Subscription has a billing issue that requires user attention
    case billingIssue
    
    /// Subscription was previously active but has now expired
    case expired(expirationDate: Date?)
    
    /// Unknown or unresolvable status (e.g. initial offline launch before cached info is read)
    case unknown
    
    /// Helper boolean checking if the user currently holds active Pro privileges
    public var isPro: Bool {
        switch self {
        case .activeAnnual, .activeLifetime, .inGracePeriod:
            return true
        case .loading, .notSubscribed, .billingIssue, .expired, .unknown:
            return false
        }
    }
    
    /// Returns true if current active entitlement is a non-recurring Lifetime purchase
    public var isLifetime: Bool {
        switch self {
        case .activeLifetime:
            return true
        default:
            return false
        }
    }
    
    /// User-friendly localized display title
    public var displayTitle: String {
        switch self {
        case .loading:
            return "Checking Status..."
        case .notSubscribed:
            return "Free Tier"
        case .activeAnnual(_, _, let isTrial):
            return isTrial ? "Relyvo Pro (Trial Active)" : "Relyvo Pro (Annual)"
        case .activeLifetime:
            return "Relyvo Forever (Lifetime)"
        case .inGracePeriod:
            return "Relyvo Pro (Grace Period)"
        case .billingIssue:
            return "Billing Issue"
        case .expired:
            return "Relyvo Pro (Expired)"
        case .unknown:
            return "Status Unavailable"
        }
    }
}

// MARK: - Package Type Classification

public enum SubscriptionPackageType: Equatable, Sendable {
    case annual
    case lifetime
    case other(String)
}

// MARK: - Subscription Package Model

/// Clean SwiftUI-friendly wrapper around RevenueCat's Package model
public struct SubscriptionPackage: Identifiable, Sendable {
    public var id: String { underlyingPackage.identifier }
    
    public let underlyingPackage: Package
    public let packageType: SubscriptionPackageType
    public let title: String
    public let subtitle: String
    public let localizedPrice: String
    public let periodDescription: String
    public let hasFreeTrial: Bool
    public let trialPeriodDescription: String?
    public let isPopular: Bool
    public let isLifetime: Bool
    
    public init(package: Package) {
        self.underlyingPackage = package
        let storeProduct = package.storeProduct
        let pkgIdentifier = package.identifier
        let productID = storeProduct.productIdentifier
        
        // Identify Package Type
        let isAnnual = pkgIdentifier == Constants.Subscriptions.annualPackageID ||
            productID == Constants.Subscriptions.annualProductID ||
            productID == Constants.Subscriptions.legacyAnnualProductID ||
            package.packageType == .annual
        
        let isLifetime = pkgIdentifier == Constants.Subscriptions.lifetimePackageID ||
            productID == Constants.Subscriptions.lifetimeProductID ||
            productID == Constants.Subscriptions.legacyLifetimeProductID ||
            package.packageType == .lifetime
        
        if isAnnual {
            self.packageType = .annual
            self.isLifetime = false
            self.isPopular = true
            self.title = Constants.Subscriptions.annualDisplayName
            self.subtitle = "Unlimited encrypted mesh, Opus voice & radar"
        } else if isLifetime {
            self.packageType = .lifetime
            self.isLifetime = true
            self.isPopular = false
            self.title = Constants.Subscriptions.lifetimeDisplayName
            self.subtitle = "Pay once, own forever. Zero recurring fees."
        } else {
            self.packageType = .other(pkgIdentifier)
            self.isLifetime = false
            self.isPopular = false
            self.title = storeProduct.localizedTitle.isEmpty ? pkgIdentifier.capitalized : storeProduct.localizedTitle
            self.subtitle = storeProduct.localizedDescription
        }
        
        self.localizedPrice = storeProduct.localizedPriceString
        
        // Billing Period Description
        if self.isLifetime {
            self.periodDescription = "one-time"
        } else if let period = storeProduct.subscriptionPeriod {
            switch period.unit {
            case .day:
                self.periodDescription = period.value == 1 ? "day" : "\(period.value) days"
            case .week:
                self.periodDescription = period.value == 1 ? "week" : "\(period.value) weeks"
            case .month:
                self.periodDescription = period.value == 1 ? "month" : "\(period.value) months"
            case .year:
                self.periodDescription = period.value == 1 ? "year" : "\(period.value) years"
            @unknown default:
                self.periodDescription = "year"
            }
        } else {
            self.periodDescription = "one-time"
        }
        
        // Introductory / Free Trial
        if let intro = storeProduct.introductoryDiscount, intro.paymentMode == .freeTrial {
            self.hasFreeTrial = true
            let unit = intro.subscriptionPeriod.unit
            let value = intro.subscriptionPeriod.value
            switch unit {
            case .day:
                self.trialPeriodDescription = "\(value)-day free trial"
            case .week:
                self.trialPeriodDescription = "\(value)-week free trial"
            case .month:
                self.trialPeriodDescription = "\(value)-month free trial"
            case .year:
                self.trialPeriodDescription = "\(value)-year free trial"
            @unknown default:
                self.trialPeriodDescription = "Free trial included"
            }
        } else {
            self.hasFreeTrial = false
            self.trialPeriodDescription = nil
        }
    }
}

// MARK: - Purchase & Restore Outcomes

/// Outcome of a user-initiated purchase action
public enum PurchaseOutcome: Sendable {
    case success(customerInfo: CustomerInfo)
    case cancelled
    case pending
    case error(message: String)
}

/// Outcome of a user-initiated restore purchases action
public enum RestoreOutcome: Sendable {
    case restored(tier: String, isLifetime: Bool, expirationDate: Date?)
    case noActiveEntitlements
    case failed(message: String)
}
