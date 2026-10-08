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
// Account-number recovery: the minted number is stored only in this device's
// App Group container (iCloud Keychain sync is NOT implemented yet), so a
// reinstall or a second Apple device recovers via "Restore Purchases", which
// issues an additional number for the same subscription (restore=true). Older
// numbers stay valid server-side, so other devices are not signed out. If the
// API ever rejects the stored number, TunnelManager recovers silently through
// redeemCurrentEntitlement().

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
    @Published private(set) var loadState: LoadState = .idle

    /// Kept so existing call sites that read `loadFailed` keep compiling.
    var loadFailed: Bool { loadState.isFailure }

    /// Distinguishes "Apple answered and had nothing for us" from "we never
    /// reached Apple." The previous code collapsed both into a single
    /// "check your connection" message — which is what App Review saw on
    /// 2026-08-12, and which pointed at the one thing that wasn't wrong.
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// StoreKit answered successfully but returned zero products.
        case empty(storefront: String)
        /// StoreKit threw before it could answer.
        case failed(detail: String)

        var isFailure: Bool {
            switch self {
            case .empty, .failed:          return true
            case .idle, .loading, .loaded: return false
            }
        }

        var message: String? {
            switch self {
            case .empty:
                return "No plans are available on this Apple Account right now. "
                     + "This isn't a problem with your connection — please try again."
            case .failed:
                return "Couldn't reach the App Store. If you're connected to "
                     + "Lattice, disconnect and try again."
            case .idle, .loading, .loaded:
                return nil
            }
        }

        /// Short technical detail for the small secondary line. Contains no
        /// user data — it exists so that a failure is diagnosable from a
        /// screenshot instead of requiring three weeks of guessing.
        var diagnostic: String? {
            switch self {
            case .empty(let storefront):   return "No products returned (storefront: \(storefront))"
            case .failed(let detail):      return detail
            case .idle, .loading, .loaded: return nil
            }
        }
    }

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

    /// Loads the four subscription products, retrying briefly on transient
    /// failure.
    ///
    /// The original implementation loaded exactly once. SwiftUI cancels a
    /// `.task` when its view is torn down — on iPad that happens for rotation,
    /// Split View and Stage Manager, none of which occur on iPhone — and the
    /// resulting throw was recorded as a permanent failure with no way back.
    /// One bad moment killed the only screen that sells anything.
    func loadProducts(retries: Int = 2) async {
        loadState = .loading
        var lastThrownDetail: String?

        for attempt in 0...retries {
            if attempt > 0 {
                let ns: UInt64 = attempt == 1 ? 1_000_000_000 : 3_000_000_000
                try? await Task.sleep(nanoseconds: ns)
                // Don't keep retrying into a torn-down view.
                if Task.isCancelled { return }
            }

            do {
                let fetched = try await Product.products(for: Self.productIDs)
                if !fetched.isEmpty {
                    products = fetched
                    loadState = .loaded
                    return
                }
                // Reached Apple and got nothing back. Clear any earlier thrown
                // error so we report .empty rather than a stale network message.
                lastThrownDetail = nil
            } catch is CancellationError {
                return
            } catch {
                lastThrownDetail = (error as NSError).localizedDescription
            }
        }

        products = []

        if let detail = lastThrownDetail {
            loadState = .failed(detail: detail)
        } else {
            // A nil storefront means StoreKit never established an App Store
            // session at all; a real country code means the session was fine
            // and the account genuinely served nothing.
            let storefront = await Storefront.current
            loadState = .empty(storefront: storefront?.countryCode ?? "none")
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
        if let number = try await Self.redeemCurrentEntitlement() {
            return number
        }
        throw StoreError.nothingToRestore
    }

    /// Redeem this device's current App Store entitlement for an account
    /// number, WITHOUT calling AppStore.sync() — so it never shows an Apple ID
    /// password prompt and is safe to run silently in the background.
    ///
    /// Returns nil when this device holds no verified Lattice subscription
    /// (e.g. the customer subscribed on the web and typed their number in).
    /// The returned string may be empty if the server sent no number.
    ///
    /// Used by TunnelManager to recover from an account number the server no
    /// longer recognizes (HTTP 401). The server keeps previously issued numbers
    /// valid on a restore, so this does not sign out the customer's other
    /// devices. REQUIRES the server change that added account_number_aliases;
    /// against an older server, every restore replaced the only valid number.
    static func redeemCurrentEntitlement() async throws -> String? {
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.productType == .autoRenewable,
                  productIDs.contains(transaction.productID) else { continue }
            return try await IAPClient.redeem(
                signedTransaction: entitlement.jwsRepresentation, restore: true)
        }
        return nil
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
