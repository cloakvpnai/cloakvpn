// SPDX-License-Identifier: MIT
//
// Lattice VPN — in-app purchase paywall (App Store Guideline 3.1.1).
//
// Presented from AccountEntryView for customers who don't yet have an account
// number. Buying a plan here goes through StoreKit In-App Purchase; on success
// the server mints an account number which we feed straight into the existing
// sign-in path, so the rest of the app is unchanged.

import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var store = StoreManager()

    private let termsURL = URL(string: "https://latticevpn.ai/terms")!
    private let privacyURL = URL(string: "https://latticevpn.ai/privacy")!

    @State private var busyProductID: String?
    @State private var restoring = false
    @State private var error: String?
    /// The plan the user tapped — only this row shows the green outline.
    @State private var selectedProductID: String?

    private var anyBusy: Bool { busyProductID != nil || restoring || tunnel.signInBusy }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.09, blue: 0.13),
                         Color(red: 0.03, green: 0.04, blue: 0.06)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(CloakDesign.brandGreen)
                        .padding(.top, 36)
                        .padding(.bottom, 14)

                    Text("Choose your plan")
                        .font(CloakDesign.headline(size: 24, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("No email, no password. After you subscribe you get an account number — your only key. Yearly plans give you two months free.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 26)

                    if store.loadFailed {
                        Text("Couldn't load plans. Check your connection and try again.")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .padding(.bottom, 16)
                    }

                    ForEach(store.sortedProducts, id: \.id) { product in
                        planRow(product)
                    }

                    if let error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, 14)
                    }

                    Button(action: restore) {
                        if restoring {
                            ProgressView().tint(.white)
                        } else {
                            Text("Restore Purchases")
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 24)
                    .disabled(anyBusy)

                    Text("Payment is charged to your Apple Account at confirmation of purchase. Subscriptions renew automatically for the same price and duration unless cancelled at least 24 hours before the period ends. Manage or cancel anytime in your Apple ID settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.top, 18)
                        .padding(.horizontal, 12)

                    // Required for auto-renewable subscriptions (Guideline 3.1.2):
                    // functional Terms of Use (EULA) + Privacy Policy links in
                    // the purchase flow.
                    HStack(spacing: 18) {
                        Button("Terms of Use") { openURL(termsURL) }
                        Text("·").foregroundStyle(.white.opacity(0.3))
                        Button("Privacy Policy") { openURL(privacyURL) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CloakDesign.brandGreen)
                    .padding(.top, 14)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 40)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(16)
            .disabled(anyBusy)
        }
        .task { await store.loadProducts() }
    }

    @ViewBuilder
    private func planRow(_ product: Product) -> some View {
        let selected = (selectedProductID == product.id)
        Button {
            buy(product)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(product.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(product.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                }
                Spacer()
                if busyProductID == product.id {
                    ProgressView().tint(.white)
                } else {
                    Text(product.displayPrice)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selected ? CloakDesign.brandGreen : Color.white.opacity(0.15),
                                    lineWidth: selected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
        .disabled(anyBusy)
    }

    private func buy(_ product: Product) {
        guard !anyBusy else { return }
        error = nil
        selectedProductID = product.id   // highlight only the tapped plan
        busyProductID = product.id
        Task {
            defer { busyProductID = nil }
            do {
                switch try await store.purchase(product) {
                case .success(let number):
                    await signInAndDismiss(number)
                case .pending:
                    error = "Your purchase is pending approval. You'll be signed in once it's approved."
                case .cancelled:
                    break
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func restore() {
        guard !anyBusy else { return }
        error = nil
        restoring = true
        Task {
            defer { restoring = false }
            do {
                let number = try await store.restore()
                await signInAndDismiss(number)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Feed the minted account number into the existing sign-in path. On
    /// success the tunnel flips isSignedIn and ContentView dismisses both this
    /// sheet and the account-entry cover.
    private func signInAndDismiss(_ number: String) async {
        guard !number.isEmpty else {
            error = "Subscription confirmed, but no account number was returned. Try Restore Purchases."
            return
        }
        if let err = await tunnel.signIn(number) {
            error = err
        } else {
            dismiss()
        }
    }
}
