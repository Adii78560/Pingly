//
//  SubscriptionManager.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 05/09/26.
//

import Foundation
import SwiftUI
import Combine
import RevenueCat
import os
import OSLog

/// Centralized, production-grade RevenueCat subscription orchestrator for Relyvo Pro & Lifetime
/// Single authoritative source of truth for all in-app subscription entitlements, offerings, purchases, and restore flows.
@MainActor
public final class SubscriptionManager: NSObject, ObservableObject, SubscriptionServiceProtocol, PurchasesDelegate {
    
    // MARK: - Singleton
    
    public static let shared = SubscriptionManager()
    
    // MARK: - Published Properties
    
    @Published public private(set) var status: SubscriptionStatus = .loading
    @Published public private(set) var customerInfo: CustomerInfo?
    @Published public private(set) var currentOffering: Offering?
    @Published public private(set) var availablePackages: [SubscriptionPackage] = []
    
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isPurchasing: Bool = false
    @Published public private(set) var isRestoring: Bool = false
    @Published public private(set) var errorMessage: String?
    
    // MARK: - Computed Helpers
    
    public var isPro: Bool {
        return status.isPro
    }
    
    /// Dynamically resolved Annual subscription package
    public var annualPackage: SubscriptionPackage? {
        return availablePackages.first(where: { $0.packageType == .annual }) ??
            availablePackages.first(where: { $0.underlyingPackage.packageType == .annual })
    }
    
    /// Dynamically resolved Lifetime purchase package
    public var lifetimePackage: SubscriptionPackage? {
        return availablePackages.first(where: { $0.packageType == .lifetime }) ??
            availablePackages.first(where: { $0.underlyingPackage.packageType == .lifetime })
    }
    
    public var purchaseInProgress: Bool {
        return isPurchasing
    }
    
    public var restoringPurchases: Bool {
        return isRestoring
    }
    
    public func clearError() {
        self.errorMessage = nil
    }
    
    // MARK: - Private Properties
    
    private var isConfigured: Bool = false
    private let entitlementID: String
    private var lastForegroundRefresh: Date = .distantPast
    
    // MARK: - Initialization
    
    public override init() {
        self.entitlementID = Constants.Subscriptions.entitlementID
        super.init()
    }
    
    public init(entitlementID: String) {
        self.entitlementID = entitlementID
        super.init()
    }
    
    // MARK: - Configuration & Setup
    
    /// Initializes and configures RevenueCat SDK instance. Safe to call multiple times (idempotent).
    public func configure(appUserID: String? = nil) {
        guard !isConfigured else {
            return
        }
        
        let apiKey = Constants.Subscriptions.testApiKey
        
        #if DEBUG
        Purchases.logLevel = .debug
        #else
        Purchases.logLevel = .warn
        #endif
        
        // Configure RevenueCat Purchases instance
        let builder = Configuration.Builder(withAPIKey: apiKey)
        if let appUserID = appUserID, !appUserID.isEmpty {
            builder.with(appUserID: appUserID)
        }
        
        Purchases.configure(with: builder.build())
        Purchases.shared.delegate = self
        self.isConfigured = true
        
        
        // Non-blocking asynchronous initial load
        Task {
            await self.initialLoad()
        }
    }
    
    private func initialLoad() async {
        self.isLoading = true
        defer { self.isLoading = false }
        
        do {
            let info = try await Purchases.shared.customerInfo()
            self.updateCustomerInfo(info)
        } catch {
            // If offline, check if RevenueCat has cached customer info available
            if let cachedInfo = Purchases.shared.cachedCustomerInfo {
                self.updateCustomerInfo(cachedInfo)
            } else {
                self.status = .notSubscribed
            }
        }
        
        // Pre-fetch offerings in background
        do {
            _ = try await self.fetchOfferings()
        } catch {
        }
    }
    
    // MARK: - PurchasesDelegate (Real-Time CustomerInfo Updates)
    
    public nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in
            self.updateCustomerInfo(customerInfo)
        }
    }
    
    // MARK: - Entitlement & State Calculation
    
    /// Parses CustomerInfo and deterministically computes the domain `SubscriptionStatus`
    public func updateCustomerInfo(_ info: CustomerInfo) {
        self.customerInfo = info
        
        let appUserID = Purchases.isConfigured ? Purchases.shared.appUserID : "unconfigured"
        let activeEntitlements = info.entitlements.active.keys.sorted()
        let proEntitlement = info.entitlements[self.entitlementID]
        let proFound = proEntitlement != nil
        let proActive = proEntitlement?.isActive == true
        
        
        if let entitlement = proEntitlement {
            if entitlement.isActive {
                let productID = entitlement.productIdentifier
                let isLifetime = productID == Constants.Subscriptions.lifetimeProductID ||
                    productID == Constants.Subscriptions.legacyLifetimeProductID ||
                    entitlement.expirationDate == nil
                
                if isLifetime {
                    self.status = .activeLifetime
                } else {
                    let isTrial = entitlement.periodType == .trial
                    let willRenew = entitlement.willRenew
                    let expirationDate = entitlement.expirationDate
                    
                    self.status = .activeAnnual(
                        expirationDate: expirationDate,
                        willRenew: willRenew,
                        isTrial: isTrial
                    )
                }
            } else if let expirationDate = entitlement.expirationDate, expirationDate > Date() {
                self.status = .inGracePeriod(expirationDate: expirationDate)
            } else {
                self.status = .expired(expirationDate: entitlement.expirationDate)
            }
        } else {
            self.status = .notSubscribed
        }
        
    }
    
    // MARK: - Customer Identity (Apple ID / IdentityManager Synchronization)
    
    /// Synchronizes Relyvo's authenticated user identity with RevenueCat
    public func identify(appUserID: String) async throws {
        guard !appUserID.isEmpty else { return }
        guard Purchases.isConfigured else { return }
        
        let currentAppUserID = Purchases.shared.appUserID
        if currentAppUserID == appUserID {
            return
        }
        
        let (info, created) = try await Purchases.shared.logIn(appUserID)
        self.updateCustomerInfo(info)
    }
    
    /// Resets customer identity upon sign out or account deletion
    public func resetIdentity() async throws {
        guard Purchases.isConfigured else { return }
        
        let info = try await Purchases.shared.logOut()
        self.updateCustomerInfo(info)
    }
    
    // MARK: - Fetch Offerings & CustomerInfo
    
    public func fetchCustomerInfo() async throws -> CustomerInfo {
        self.isLoading = true
        defer { self.isLoading = false }
        
        let info = try await Purchases.shared.customerInfo()
        self.updateCustomerInfo(info)
        return info
    }
    
    public func fetchOfferings() async throws -> Offerings {
        guard Purchases.isConfigured else {
            throw NSError(domain: "SubscriptionManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "RevenueCat is not configured."])
        }
        
        self.isLoading = true
        defer { self.isLoading = false }
        
        let offerings = try await Purchases.shared.offerings()
        
        if let current = offerings.offering(identifier: Constants.Subscriptions.offeringID) ?? offerings.current {
            self.currentOffering = current
            self.availablePackages = current.availablePackages.map { pkg in
                return SubscriptionPackage(package: pkg)
            }
            for pkg in current.availablePackages {
            }
        } else {
            self.currentOffering = nil
            self.availablePackages = []
        }
        
        return offerings
    }
    
    // MARK: - Purchase Flow (With Race Condition Protection)
    
    public func purchase(package: SubscriptionPackage) async -> PurchaseOutcome {
        // Prevent duplicate concurrent purchase requests
        guard !self.isPurchasing else {
            return .error(message: "A purchase transaction is already in progress.")
        }
        
        guard Purchases.isConfigured else {
            return .error(message: "Payment service is currently unavailable. Please restart the app.")
        }
        
        self.isPurchasing = true
        self.errorMessage = nil
        defer { self.isPurchasing = false }
        
        let productID = package.underlyingPackage.storeProduct.productIdentifier
        
        do {
            let purchaseResult = try await Purchases.shared.purchase(package: package.underlyingPackage)
            
            if purchaseResult.userCancelled {
                return .cancelled
            }
            
            
            // Update customer status immediately from authoritative RevenueCat CustomerInfo
            self.updateCustomerInfo(purchaseResult.customerInfo)
            
            if self.isPro {
                return .success(customerInfo: purchaseResult.customerInfo)
            } else {
                return .pending
            }
        } catch let error as RevenueCat.ErrorCode {
            switch error {
            case .purchaseCancelledError:
                return .cancelled
            case .purchaseNotAllowedError:
                let msg = "Purchases are not allowed on this device or Apple ID."
                self.errorMessage = msg
                return .error(message: msg)
            case .productAlreadyPurchasedError:
                do {
                    let info = try await self.fetchCustomerInfo()
                    if self.isPro {
                        return .success(customerInfo: info)
                    }
                } catch {}
                return .error(message: "You already own this product.")
            case .networkError:
                let msg = "Please check your internet connection and try again."
                self.errorMessage = msg
                return .error(message: msg)
            default:
                let msg = error.localizedDescription
                self.errorMessage = msg
                return .error(message: msg)
            }
        } catch {
            let msg = "Something went wrong. Please try again."
            self.errorMessage = msg
            return .error(message: msg)
        }
    }
    
    // MARK: - Restore Purchases Flow (With Verification & Anti-Spam)
    
    public func restorePurchases() async -> RestoreOutcome {
        // Prevent duplicate concurrent restore requests
        guard !self.isRestoring else {
            return .failed(message: "A restore operation is already in progress.")
        }
        
        guard Purchases.isConfigured else {
            return .failed(message: "Payment service is currently unavailable.")
        }
        
        self.isRestoring = true
        self.errorMessage = nil
        defer { self.isRestoring = false }
        
        
        do {
            let info = try await Purchases.shared.restorePurchases()
            self.updateCustomerInfo(info)
            
            if let entitlement = info.entitlements[self.entitlementID], entitlement.isActive {
                let productID = entitlement.productIdentifier
                let isLifetime = productID == Constants.Subscriptions.lifetimeProductID || entitlement.expirationDate == nil
                let tierName = isLifetime ? Constants.Subscriptions.lifetimeDisplayName : Constants.Subscriptions.annualDisplayName
                
                return .restored(tier: tierName, isLifetime: isLifetime, expirationDate: entitlement.expirationDate)
            } else {
                return .noActiveEntitlements
            }
        } catch {
            let msg = "Unable to restore purchases right now. Please check your internet connection and try again."
            self.errorMessage = msg
            return .failed(message: msg)
        }
    }
    
    // MARK: - Lifecycle Refresh (Foreground Throttling)
    
    /// Refreshes subscription status when the app enters the foreground, throttled to at most once every 60 seconds
    public func refreshStateOnForeground() {
        guard Purchases.isConfigured else { return }
        
        let now = Date()
        guard now.timeIntervalSince(self.lastForegroundRefresh) >= 60 else {
            return
        }
        self.lastForegroundRefresh = now
        
        Task {
            do {
                _ = try await self.fetchCustomerInfo()
            } catch {
            }
        }
    }
}
