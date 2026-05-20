//
//  PaywallView.swift
//  Lattice VPN
//
//  The subscription purchase screen. Lists the four products from
//  StoreKitManager (Basic / Pro × Monthly / Yearly), lets the user
//  buy one, and offers Restore Purchases.
//
//  Presented as a sheet from the Settings drawer. All purchase logic
//  lives in StoreKitManager — this file is purely presentation.
//
//  Prices are NOT hardcoded here: `Product.displayPrice` gives the
//  correctly-localized, currency-correct string straight from the App
//  Store (or the local Lattice.storekit file when testing).
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @ObservedObject private var store = StoreKitManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Which tier's column the user is looking at. Defaults to Pro —
    /// the plan we'd like to anchor on.
    @State private var selectedTier: SubscriptionTier = .pro

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    tierPicker
                    planCards
                    featureList
                    restoreButton
                    legalFooter
                }
                .padding(20)
            }
            .navigationTitle("Choose your plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay {
                if store.isBusy {
                    ProgressView().controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { store.lastError != nil },
                    set: { if !$0 { store.lastError = nil } }
                ),
                presenting: store.lastError
            ) { _ in
                Button("OK", role: .cancel) { store.lastError = nil }
            } message: { Text($0) }
        }
        .task {
            if store.products.isEmpty { await store.loadProducts() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Post-quantum protection for every device")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Every plan includes post-quantum encryption and a strict no-logs policy. Pro adds wider coverage and convenience.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var tierPicker: some View {
        Picker("Tier", selection: $selectedTier) {
            Text("Basic").tag(SubscriptionTier.basic)
            Text("Pro").tag(SubscriptionTier.pro)
        }
        .pickerStyle(.segmented)
    }

    /// Monthly + yearly cards for the currently-selected tier.
    private var planCards: some View {
        let tierProducts = store.products.filter {
            StoreKitManager.ProductID.tier(for: $0.id) == selectedTier
        }
        return VStack(spacing: 12) {
            if tierProducts.isEmpty {
                Text("Subscription options are loading…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(tierProducts, id: \.id) { product in
                    planCard(product)
                }
            }
        }
    }

    private func planCard(_ product: Product) -> some View {
        let period = store.billingPeriod(for: product)
        let isCurrent = (store.activeProductID == product.id)
        let isYearly = (period == "year")
        return Button {
            Task { await store.purchase(product) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(isYearly ? "Annual" : "Monthly")
                            .font(.system(size: 15, weight: .semibold))
                        if isYearly {
                            Text("2 MONTHS FREE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.tint, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Text("\(product.displayPrice) / \(period)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isCurrent ? Color.secondary.opacity(0.4) : Color.accentColor,
                            lineWidth: isCurrent ? 1 : 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || store.isBusy)
    }

    /// The Basic-vs-Pro feature breakdown for the selected tier.
    private var featureList: some View {
        let proOnly = [
            "AI phishing, tracker & malware shield",
            "Split tunneling",
            "Custom / encrypted DNS",
            "Obfuscated / bridge servers",
            "All server locations",
            "Priority support",
        ]
        let basicFeatures = [
            "Post-quantum encryption (Rosenpass + WireGuard)",
            "Strict no-logs, RAM-only servers",
            "iOS + Android apps",
            "3 devices  ·  Core EU + US locations",
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text(selectedTier == .pro ? "Everything in Basic, plus:" : "Included")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(selectedTier == .pro ? proOnly : basicFeatures, id: \.self) { feature in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tint)
                    Text(feature)
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var restoreButton: some View {
        VStack(spacing: 10) {
            // Shown only once the user actually has an active sub —
            // routes to the system Manage Subscriptions sheet for
            // upgrades, downgrades, and cancellation.
            if store.activeTier != nil {
                Button("Manage or cancel subscription") {
                    Task { await store.showManageSubscriptions() }
                }
                .font(.system(size: 13, weight: .semibold))
                .disabled(store.isBusy)
            }
            Button("Restore Purchases") {
                Task { await store.restore() }
            }
            .font(.system(size: 13, weight: .medium))
            .disabled(store.isBusy)
        }
    }

    private var legalFooter: some View {
        VStack(spacing: 4) {
            Text("Subscriptions renew automatically until cancelled. Cancel anytime in Settings. Payment is charged to your Apple Account.")
            HStack(spacing: 4) {
                Link("Terms", destination: URL(string: "https://latticevpn.ai/terms")!)
                Text("·")
                Link("Privacy", destination: URL(string: "https://latticevpn.ai/privacy")!)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 4)
    }
}

#Preview {
    PaywallView()
}
