// SPDX-License-Identifier: MIT
//
// Lattice VPN — StoreKit 2 in-app-purchase manager.
//
// Compliance (App Store Guideline 3.1.1): paid VPN access on iOS is sold via
// In-App Purchase. A purchase here produces a signed StoreKit transaction
// (JWS) which we hand to the server (POST /v1/iap). The server verifies it
// against Apple's signature and mints/extends an account number, which we then
// feed into the existing account-number sign-in path (TunnelManager.signIn).
// The account number remains the single credential the VPN layer uses — IAP is
// just a second way to obtain one, alongside web/Stripe.
//
// Account-number recovery: the minted number is stored in the iCloud Keychain
// (synchronizable) by the sign-in path, so a reinstall or a second Apple
// device can recover it. If that fails, "Restore Purchases" re-issues a fresh
// number from the same subscription (restore=true).

import Combine
import Foundation
import StoreKit

@MainActor
final class StoreManager: ObservableObject {

    /// Must match the auto-renewable subscription product IDs in App Store
    /// Connect and the server's APPLE_PRODUCT_* config.
    static let productIDs: [String] = [
        "ai.cloakvpn.CloakVPN.basic.monthly",
        "ai.cloakvpn.CloakVPN.basic.yearly",
        "ai.cloakvpn.CloakVPN.pro.monthly",
        "ai.cloakvpn.CloakVPN.pro.yearly",
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var loadFailed = false

    private var updatesTask: Task<Void, Never>?

    init() {
        // Drain StoreKit's transaction updates (renewals, refunds, Ask-to-Buy
        // approvals) for the life of the app so they're acknowledged. The
        // server is the source of truth for entitlement via App Store Server
        // Notifications; here we just finish them so they don't replay.
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self else { continue }
                if case .verified(let txn) = update {
                    await txn.finish()
                }
            }
        }
    }

    deinit { updatesTask?.cancel() }

    /// Products sorted Basic→Pro, monthly→yearly for stable paywall ordering.
    var sortedProducts: [Product] {
        products.sorted { a, b in
            Self.productIDs.firstIndex(of: a.id) ?? 0 < (Self.productIDs.firstIndex(of: b.id) ?? 0)
        }
    }

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            self.products = fetched
            self.loadFailed = fetched.isEmpty
        } catch {
            self.loadFailed = true
        }
    }

    enum PurchaseOutcome {
        case success(accountNumber: String)
        case pending          // Ask-to-Buy / SCA — entitlement arrives later
        case cancelled
    }

    /// Buy `product`, verify it server-side, and return the minted account
    /// number on success. Throws on verification/network failure.
    func purchase(_ product: Product) async throws -> PurchaseOutcome {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw StoreError.unverified
            }
            // Hand Apple's signed JWS to our server to mint/extend the account.
            let number = try await IAPClient.redeem(
                signedTransaction: verification.jwsRepresentation, restore: false)
            await transaction.finish()
            return .success(accountNumber: number)
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    /// Restore: re-sync with the App Store, find the current entitlement, and
    /// ask the server to re-issue this subscription's account number.
    func restore() async throws -> String {
        try? await AppStore.sync()
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.productType == .autoRenewable,
                  Self.productIDs.contains(transaction.productID) else { continue }
            let number = try await IAPClient.redeem(
                signedTransaction: entitlement.jwsRepresentation, restore: true)
            return number
        }
        throw StoreError.nothingToRestore
    }

    enum StoreError: LocalizedError {
        case unverified, nothingToRestore, server(String)
        var errorDescription: String? {
            switch self {
            case .unverified:      return "Apple couldn't verify that purchase. Please try again."
            case .nothingToRestore: return "No active Lattice subscription found on this Apple ID."
            case .server(let m):   return m
            }
        }
    }
}

/// Thin client for POST /v1/iap. Kept separate from LatticeAccountClient
/// because the request shape (signed transaction in, account number out) is
/// IAP-specific.
enum IAPClient {
    private struct Req: Encodable { let signed_transaction: String; let restore: Bool }
    private struct Resp: Decodable { let account_number: String?; let tier: String?; let active_until: String? }

    /// Returns the account number the server minted or re-issued. May be empty
    /// on a plain renewal re-verify (caller already holds its number).
    static func redeem(signedTransaction: String, restore: Bool) async throws -> String {
        guard let url = URL(string: "\(LatticeAPI.baseURL)/v1/iap") else {
            throw StoreManager.StoreError.server("Bad API URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(signed_transaction: signedTransaction, restore: restore))

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        let (data, resp) = try await URLSession(configuration: cfg).data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw StoreManager.StoreError.server("Unexpected response from Lattice.")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 402 {
                throw StoreManager.StoreError.server("That subscription isn't active. If you just purchased, try again in a moment.")
            }
            throw StoreManager.StoreError.server("Lattice couldn't validate the purchase (\(http.statusCode)).")
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return decoded.account_number ?? ""
    }
}
