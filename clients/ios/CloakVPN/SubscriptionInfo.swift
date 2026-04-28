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
// When IAP integration ships, replace `SubscriptionInfo.current` with
// a real loader (StoreKit transaction observer + receipt validation).

import Foundation

enum SubscriptionTier: String, Codable {
    case basic
    case pro

    var displayName: String {
        switch self {
        case .basic: return "Basic"
        case .pro:   return "Pro"
        }
    }
}

struct SubscriptionInfo: Codable, Equatable {
    let accountID: String          // user-facing account identifier
    let tier: SubscriptionTier
    let renewalDate: Date?         // nil for lifetime / no expiration

    /// Hardcoded placeholder. Replace with real StoreKit-backed loader
    /// when subscription billing infrastructure is in place.
    static var current: SubscriptionInfo {
        SubscriptionInfo(
            accountID: "guest",
            tier: .basic,
            renewalDate: nil
        )
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
