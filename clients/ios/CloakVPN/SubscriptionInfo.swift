// SPDX-License-Identifier: MIT
//
// Cloak VPN — Subscription info (placeholder).
//
// This is the customer-account stand-in. Real implementation requires
// Stripe / App Store In-App Purchase integration + a Cloak account
// backend (TBD). For tonight's UI work we hardcode a placeholder so
// the Settings sheet has something to render and the existing UI
// surfaces are wired through to the real shape.
//
// When IAP integration ships, replace the UserDefaults-backed loader
// below with a real StoreKit transaction observer + receipt validation.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum SubscriptionTier: String, Codable {
    case basic
    case pro

    var displayName: String {
        switch self {
        case .basic: return "Basic"
        case .pro:   return "Pro"
        }
    }

    /// Name of the alternate icon (registered in Info.plist's
    /// CFBundleAlternateIcons) that should be active for this tier.
    /// `nil` means "use the primary icon" — i.e. the AppIcon in the
    /// asset catalog, which today is the gold "CLOAKVPN" mark.
    var alternateIconName: String? {
        switch self {
        case .basic: return nil               // primary AppIcon (CLOAKVPN)
        case .pro:   return "CloakProIcon"    // CLOAKVPN PRO logo
        }
    }
}

struct SubscriptionInfo: Codable, Equatable {
    let accountID: String          // user-facing account identifier
    let tier: SubscriptionTier
    let renewalDate: Date?         // nil for lifetime / no expiration

    private static let userDefaultsKey = "subscriptionTier"

    /// Loaded from UserDefaults so the Pro/Basic toggle in the Settings
    /// drawer persists across app launches. Until real IAP / receipt
    /// validation ships, the user can flip the tier manually for
    /// preview / demo purposes.
    static var current: SubscriptionInfo {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey)
        let tier = SubscriptionTier(rawValue: raw ?? "") ?? .basic
        return SubscriptionInfo(
            accountID: "guest",
            tier: tier,
            renewalDate: nil
        )
    }

    /// Persist a new tier and apply the matching app icon. Idempotent —
    /// safe to call repeatedly with the same tier.
    static func setTier(_ tier: SubscriptionTier) {
        UserDefaults.standard.set(tier.rawValue, forKey: userDefaultsKey)
        applyIconForTier(tier)
    }

    /// Apply the alternate-icon assignment matching the given tier.
    /// Wraps UIApplication.setAlternateIconName with a few safety nets:
    ///
    /// - Skips the call if the requested icon is already active
    ///   (otherwise iOS shows the "icon changed" alert every time even
    ///   when nothing actually changed).
    /// - Skips if `supportsAlternateIcons` is false (e.g. running in a
    ///   stripped-down environment, or under some MDM policies).
    /// - Caps the heavy lifting to MainActor — UIApplication APIs all
    ///   require it.
    static func applyIconForTier(_ tier: SubscriptionTier) {
        #if canImport(UIKit)
        Task { @MainActor in
            let app = UIApplication.shared
            guard app.supportsAlternateIcons else {
                print("SubscriptionInfo: alternate icons not supported on this device")
                return
            }
            let target = tier.alternateIconName
            // alternateIconName returns nil when the primary is active;
            // we use the same nil-or-string convention.
            if app.alternateIconName == target {
                return  // already set, skip the alert
            }
            do {
                try await app.setAlternateIconName(target)
                print("SubscriptionInfo: switched icon to \(target ?? "primary (Basic)")")
            } catch {
                print("SubscriptionInfo: setAlternateIconName failed: \(error)")
            }
        }
        #endif
    }

    /// Convenience — apply whatever icon matches the currently-persisted
    /// tier. Call this on app launch to keep the icon in sync with the
    /// stored tier even if the user changed it on a different device or
    /// uninstalled+reinstalled (which resets the icon to primary).
    static func applyIconForCurrentTier() {
        applyIconForTier(current.tier)
    }

    var displayLine: String {
        if let r = renewalDate {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return "\(tier.displayName) plan · renews \(f.string(from: r))"
        }
        return "\(tier.displayName) plan"
    }
}
