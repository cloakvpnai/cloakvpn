// SPDX-License-Identifier: MIT
//
// Lattice VPN — subscription tier + app-icon helper.
//
// The customer's subscription state is owned by the central account API
// (see LatticeAccountClient.AccountStatus, surfaced as
// TunnelManager.accountStatus). This file is just the small bit that
// stays local: the Basic/Pro app-icon switch.
//
// The last-known tier is mirrored into UserDefaults so the matching app
// icon can be applied at cold-start launch, before the account API has
// been queried.

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
    /// CFBundleAlternateIcons) for this tier. `nil` means "use the
    /// primary icon" — the LATTICE VPN mark in the asset catalog.
    var alternateIconName: String? {
        switch self {
        case .basic: return nil               // primary AppIcon (LATTICE VPN)
        case .pro:   return "LatticeProIcon"  // LATTICE VPN PRO logo (amber ring)
        }
    }

    /// Map a server tier string ("basic"/"pro", possibly empty/unknown)
    /// to a tier. An inactive or unrecognized value falls back to Basic.
    static func from(tierString raw: String) -> SubscriptionTier {
        SubscriptionTier(rawValue: raw.lowercased()) ?? .basic
    }
}

enum SubscriptionInfo {

    private static let lastKnownTierKey = "lastKnownSubscriptionTier"

    /// Persist the latest tier (from the account API) and apply the
    /// matching app icon. Call whenever account status refreshes.
    static func recordTier(_ tierString: String) {
        let tier = SubscriptionTier.from(tierString: tierString)
        UserDefaults.standard.set(tier.rawValue, forKey: lastKnownTierKey)
        applyIconForTier(tier)
    }

    /// The last tier observed from the account API, or `.basic` if none
    /// has been recorded yet.
    static var lastKnownTier: SubscriptionTier {
        let raw = UserDefaults.standard.string(forKey: lastKnownTierKey) ?? ""
        return SubscriptionTier(rawValue: raw) ?? .basic
    }

    /// Apply the alternate-icon assignment matching `tier`. Skips the call
    /// when the requested icon is already active (otherwise iOS shows its
    /// "icon changed" alert every time) or when alternate icons aren't
    /// supported on the device.
    static func applyIconForTier(_ tier: SubscriptionTier) {
        #if canImport(UIKit)
        Task { @MainActor in
            let app = UIApplication.shared
            guard app.supportsAlternateIcons else { return }
            let target = tier.alternateIconName
            if app.alternateIconName == target { return }
            do {
                try await app.setAlternateIconName(target)
            } catch {
                print("SubscriptionInfo: setAlternateIconName failed: \(error)")
            }
        }
        #endif
    }

    /// Apply whatever icon matches the last-known tier. Call on launch to
    /// keep the icon in sync even across reinstalls (which reset it to
    /// primary).
    static func applyIconForCurrentTier() {
        applyIconForTier(lastKnownTier)
    }
}
