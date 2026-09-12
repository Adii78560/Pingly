//
//  SubscriptionServiceProtocol.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 05/09/26.
//

import Foundation
import Combine
import RevenueCat

/// Protocol defining complete in-app subscription lifecycle operations for Relyvo
@MainActor
public protocol SubscriptionServiceProtocol: ObservableObject {
    /// Authoritative subscription status
    var status: SubscriptionStatus { get }
    
    /// Quick boolean flag indicating active Pro / Lifetime features
    var isPro: Bool { get }
    
    /// Raw CustomerInfo from RevenueCat (if available)
    var customerInfo: CustomerInfo? { get }
    
    /// Currently active offerings fetched from RevenueCat
    var currentOffering: Offering? { get }
    
    /// Available subscription packages formatted for UI display
    var availablePackages: [SubscriptionPackage] { get }
    
    /// Dynamically resolved Annual subscription package
    var annualPackage: SubscriptionPackage? { get }
    
    /// Dynamically resolved Lifetime purchase package
    var lifetimePackage: SubscriptionPackage? { get }
    
    /// Indicates whether a network or StoreKit operation is in-flight
    var isLoading: Bool { get }
    
    /// Indicates whether a purchase transaction is currently executing
    var isPurchasing: Bool { get }
    
    /// Alias for isPurchasing
    var purchaseInProgress: Bool { get }
    
    /// Indicates whether a restore transaction is currently executing
    var isRestoring: Bool { get }
    
    /// Alias for isRestoring
    var restoringPurchases: Bool { get }
    
    /// Last error message encountered during purchase or refresh (if any)
    var errorMessage: String? { get }
    
    /// Configures RevenueCat SDK instance on app startup
    func configure(appUserID: String?)
    
    /// Binds active user identity to RevenueCat Customer ID
    func identify(appUserID: String) async throws
    
    /// Resets user identity upon logout or account deletion
    func resetIdentity() async throws
    
    /// Fetches latest CustomerInfo from RevenueCat
    func fetchCustomerInfo() async throws -> CustomerInfo
    
    /// Fetches latest Offerings and packages from RevenueCat
    func fetchOfferings() async throws -> Offerings
    
    /// Executes purchase for a chosen package
    func purchase(package: SubscriptionPackage) async -> PurchaseOutcome
    
    /// Restores previous purchases associated with the user's Apple ID
    func restorePurchases() async -> RestoreOutcome
    
    /// Refreshes local status when app returns to foreground
    func refreshStateOnForeground()
}
