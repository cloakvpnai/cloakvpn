// SPDX-License-Identifier: MIT
//
// Lattice VPN — account-number entry (first-launch sign-in).
//
// In the no-account billing model the customer's only credential is the
// account number issued when they subscribe — there is no email and no
// password. The number is validated against the central account API
// (GET /v1/account) before it is stored, so a typo is caught here rather
// than at the first connect.
//
// The number is never emailed: for App Store purchases Apple does not give
// us the buyer's address, and the Stripe path shows the number on /welcome
// and stores it in customer metadata. Recovery therefore runs through
// Restore Purchases, which is offered on this screen.
//
// Presented as a full-screen cover by ContentView whenever no account
// number is stored. Subscribing is available and prominent here via
// See Plans (App Store Guideline 3.1.1); see docs/BILLING_INTEGRATION.md.

import SwiftUI

struct AccountEntryView: View {
    @EnvironmentObject var tunnel: TunnelManager

    @StateObject private var store = StoreManager()

    @State private var input: String = ""
    @State private var error: String?
    @State private var showPaywall = false
    @State private var restoring = false
    @FocusState private var focused: Bool

    private var complete: Bool { LatticeAPI.isComplete(input) }

    /// Binding that normalizes + re-groups the number into hyphenated
    /// fives as the customer types, and caps it at the full length.
    private var accountBinding: Binding<String> {
        Binding(
            get: { input },
            set: { raw in
                let symbols = String(LatticeAPI.normalize(raw).prefix(LatticeAPI.accountNumberLength))
                input = LatticeAPI.format(symbols)
                error = nil
            }
        )
    }

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
                        .font(.system(size: 56))
                        .foregroundStyle(CloakDesign.brandGreen)
                        .padding(.bottom, 18)

                    Text("LATTICE VPN")
                        .font(CloakDesign.headline(size: 24, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(.white)
                        .padding(.bottom, 10)

                    Text("Subscribe to get started. Post-quantum encrypted VPN, with no email and no password to remember.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 28)

                    // PRIMARY action: in-app purchase. App Store Guideline 3.1.1
                    // requires subscribing to be available and prominent inside
                    // the app, not hidden behind account-number entry.
                    Button {
                        showPaywall = true
                    } label: {
                        Text("See Plans")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CloakDesign.brandGreen)
                    .foregroundStyle(.white)
                    .padding(.bottom, 34)

                    // Secondary path: customers who already subscribed and hold
                    // an account number sign in with it.
                    Text("Already have an account number?")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 12)

                    TextField("", text: accountBinding, prompt:
                        Text("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX")
                            .foregroundColor(.white.opacity(0.35)))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(submit)
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(error != nil
                                                ? Color.red.opacity(0.8)
                                                : Color.white.opacity(0.15), lineWidth: 1)
                                )
                        )

                    if let error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }

                    Button(action: submit) {
                        ZStack {
                            if tunnel.signInBusy {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Sign In")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .tint(CloakDesign.brandGreen)
                    .foregroundStyle(.white)
                    .disabled(!complete || tunnel.signInBusy)
                    .padding(.top, 20)

                    Button("Don't have an account? See plans") {
                        showPaywall = true
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CloakDesign.brandGreen)
                    .padding(.top, 22)

                    // Recovery path for a customer who already subscribed but
                    // has no number — after a reinstall, on a new device, or
                    // having simply lost it. Restore re-verifies the App Store
                    // entitlement and the server issues a fresh number, so no
                    // email and no external link is required (Guideline 3.1.1).
                    Button(action: restore) {
                        ZStack {
                            if restoring {
                                ProgressView().tint(.white)
                            } else {
                                Text("Restore Purchases")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.8))
                    .foregroundStyle(.white)
                    .disabled(restoring || tunnel.signInBusy)
                    .padding(.top, 22)

                    Text("Subscribed on this Apple Account? Restore Purchases signs you back in with a new account number. Your previous number stops working.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(tunnel)
        }
    }

    /// Restore an existing App Store subscription and sign back in.
    ///
    /// Mirrors PaywallView.restore(), offered here as well so a returning
    /// customer never has to open the paywall — a screen that reads like it
    /// charges money — just to recover an account they already paid for.
    /// Works even when product loading fails, since StoreManager.restore()
    /// needs only AppStore.sync() and Transaction.currentEntitlements.
    private func restore() {
        guard !restoring, !tunnel.signInBusy else { return }
        focused = false
        error = nil
        restoring = true
        Task {
            defer { restoring = false }
            do {
                let number = try await store.restore()
                guard !number.isEmpty else {
                    error = "Subscription found, but no account number was returned."
                    return
                }
                // On success tunnel.isSignedIn flips and ContentView's
                // fullScreenCover dismisses this view automatically.
                if let err = await tunnel.signIn(number) { error = err }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func submit() {
        guard complete, !tunnel.signInBusy else { return }
        focused = false
        error = nil
        Task {
            // On success, tunnel.isSignedIn flips true and ContentView's
            // fullScreenCover dismisses this view automatically.
            if let err = await tunnel.signIn(input) {
                error = err
            }
        }
    }
}
