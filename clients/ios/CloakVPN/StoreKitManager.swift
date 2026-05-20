//
//  StoreKitManager.swift
//  Lattice VPN
//
//  StoreKit 2 layer for the two-tier subscription model (see
//  docs/PRICING.md). Owns: product loading, purchase, restore, the
//  lifetime transaction-update listener, and the computed current
//  entitlement (tier + renewal date).
//
//  Design notes:
//   - StoreKit 2 only (the app's deployment target is well past iOS 15).
//     No receipt-file parsing, no StoreKitTest-era cruft — everything
//     goes through `Transaction`, `Product`, and `VerificationResult`.
//   - `Transaction.updates` MUST be observed for the whole app
//     lifetime, started once at launch (see CloakVPNApp.task). It
//     delivers renewals, refunds, family-sharing changes, and
//     purchases made on other devices.
//   - Entitlement is derived ONLY from `Transaction.currentEntitlements`
//     — the StoreKit-blessed source of truth. We never trust a locally
//     cached "isPro" flag.
//   - This is the CLIENT side. Server-side enforcement (the
//     cloak-api-server gating peer provisioning on a valid
//     subscription) is a separate piece — the client entitlement here
//     drives UI + a soft gate; the server is the hard gate.
//
//  App Store Connect setup: create four auto-renewable subscriptions
//  in ONE subscription group ("Lattice VPN"), with these exact
//  product IDs (they must match `ProductID` below and Lattice.storekit):
//
//      ai.cloakvpn.CloakVPN.basic.monthly   $4.99 / 1 month   level 2
//      ai.cloakvpn.CloakVPN.basic.yearly    $49.99 / 1 year   level 2
//      ai.cloakvpn.CloakVPN.pro.monthly     $9.99 / 1 month   level 1
//      ai.cloakvpn.CloakVPN.pro.yearly      $99.99 / 1 year   level 1
//
//  Level 1 (Pro) ranks above level 2 (Basic) so StoreKit treats a
//  Basic→Pro change as an upgrade and a Pro→Basic change as a
//  downgrade. Monthly/yearly of the same tier share a level, so
//  switching billing period is a crossgrade.
//

import Combine
import Foundation
import StoreKit
import UIKit

@MainActor
final class StoreKitManager: ObservableObject {

    static let shared = StoreKitManager()

    // MARK: - Product identifiers

    /// The four auto-renewable subscription product IDs. These strings
    /// are PERMANENT once the products exist in App Store Connect —
    /// Apple does not allow deleting or reusing a product ID. Keep them
    /// in lockstep with Lattice.storekit and App Store Connect.
    enum ProductID {
        static let basicMonthly = "ai.cloakvpn.CloakVPN.basic.monthly"
        static let basicYearly  = "ai.cloakvpn.CloakVPN.basic.yearly"
        static let proMonthly   = "ai.cloakvpn.CloakVPN.pro.monthly"
        static let proYearly    = "ai.cloakvpn.CloakVPN.pro.yearly"

        static let all: [String] = [basicMonthly, basicYearly, proMonthly, proYearly]

        /// Map a product ID to the tier it grants.
        static func tier(for id: String) -> SubscriptionTier? {
            switch id {
            case basicMonthly, basicYearly: return .basic
            case proMonthly, proYearly:     return .pro
            default:                        return nil
            }
        }
    }

    // MARK: - Published state

    /// Loaded `Product`s, sorted Basic-before-Pro then Monthly-before-Yearly.
    @Published private(set) var products: [Product] = []

    /// The tier the user is currently entitled to, or nil if they have
    /// no active subscription.
    @Published private(set) var activeTier: SubscriptionTier?

    /// The product ID backing the active entitlement (so the paywall can
    /// highlight "your current plan").
    @Published private(set) var activeProductID: String?

    /// Next renewal / expiry date of the active subscription, if known.
    @Published private(set) var renewalDate: Date?

    /// True while products are loading or a purchase is in flight.
    @Published private(set) var isBusy = false

    /// Last user-facing error, surfaced by the paywall as an alert.
    @Published var lastError: String?

    // MARK: - Internals

    private var updatesListener: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Start the StoreKit layer. Call exactly once, at app launch.
    /// Begins the lifetime transaction listener and does an initial
    /// product load + entitlement refresh.
    func start() {
        guard updatesListener == nil else { return }
        updatesListener = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handleTransaction(result)
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit {
        updatesListener?.cancel()
    }

    // MARK: - Product loading

    /// Fetch the four subscription `Product`s from the App Store.
    func loadProducts() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let fetched = try await Product.products(for: ProductID.all)
            // Stable display order: Basic before Pro, Monthly before
            // Yearly. We can't rely on the order Apple returns.
            products = fetched.sorted { a, b in
                let rank: (String) -> Int = { id in
                    switch id {
                    case ProductID.basicMonthly: return 0
                    case ProductID.basicYearly:  return 1
                    case ProductID.proMonthly:   return 2
                    case ProductID.proYearly:    return 3
                    default:                     return 99
                    }
                }
                return rank(a.id) < rank(b.id)
            }
        } catch {
            lastError = "Couldn't load subscription options: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    /// Buy a subscription product. On success the transaction listener
    /// + `refreshEntitlements()` update `activeTier`.
    func purchase(_ product: Product) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlements()
            case .userCancelled:
                break   // not an error — user backed out
            case .pending:
                // Deferred (e.g. Ask to Buy / SCA). The transaction
                // listener will pick it up if/when it completes.
                lastError = "Purchase is pending approval."
            @unknown default:
                lastError = "Purchase returned an unexpected result."
            }
        } catch {
            lastError = "Purchase failed: \(error.localizedDescription)"
        }
    }

    /// Restore purchases — syncs with the App Store, then re-derives
    /// entitlement. StoreKit 2 auto-restores in most cases; this is the
    /// explicit "Restore Purchases" button path Apple requires.
    func restore() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Entitlement

    /// Re-derive `activeTier` / `activeProductID` / `renewalDate` from
    /// `Transaction.currentEntitlements` — StoreKit's source of truth.
    func refreshEntitlements() async {
        var bestTier: SubscriptionTier?
        var bestProductID: String?
        var bestRenewal: Date?

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard transaction.productType == .autoRenewable else { continue }
            // Skip anything refunded / revoked.
            if transaction.revocationDate != nil { continue }
            // Skip expired (currentEntitlements usually excludes these,
            // but be defensive).
            if let exp = transaction.expirationDate, exp < Date() { continue }

            guard let tier = ProductID.tier(for: transaction.productID) else { continue }
            // Pro outranks Basic if (somehow) both are present.
            if bestTier == nil || (tier == .pro && bestTier == .basic) {
                bestTier = tier
                bestProductID = transaction.productID
                bestRenewal = transaction.expirationDate
            }
        }

        activeTier = bestTier
        activeProductID = bestProductID
        renewalDate = bestRenewal
    }

    /// Handle a transaction delivered by the lifetime `Transaction.updates`
    /// listener (renewal, refund, cross-device purchase, etc.).
    private func handleTransaction(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(result) else { return }
        await transaction.finish()
        await refreshEntitlements()
    }

    // MARK: - Verification

    enum StoreError: LocalizedError {
        case failedVerification
        var errorDescription: String? {
            switch self {
            case .failedVerification:
                return "This purchase could not be verified by the App Store."
            }
        }
    }

    /// Unwrap a `VerificationResult`, throwing if StoreKit's
    /// cryptographic check failed (jailbreak tampering, etc.).
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Manage subscriptions

    /// Open the system "Manage Subscriptions" sheet. Called from the
    /// settings UI for users who already have an active subscription.
    func showManageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
            await refreshEntitlements()
        } catch {
            lastError = "Couldn't open subscription management: \(error.localizedDescription)"
        }
    }

    // MARK: - Display helpers

    /// Human-readable billing period for a product ("month" / "year").
    func billingPeriod(for product: Product) -> String {
        guard let sub = product.subscription else { return "" }
        switch sub.subscriptionPeriod.unit {
        case .day:   return "day"
        case .week:  return "week"
        case .month: return sub.subscriptionPeriod.value == 12 ? "year" : "month"
        case .year:  return "year"
        @unknown default: return ""
        }
    }
}
