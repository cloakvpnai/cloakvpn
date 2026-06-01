// SPDX-License-Identifier: MIT
//
// Lattice VPN — account-number entry (first-launch sign-in).
//
// In the no-account billing model the customer's only credential is the
// account number they received after subscribing at latticevpn.ai —
// there is no email and no password. The number is validated against the
// central account API (GET /v1/account) before it is stored, so a typo
// is caught here rather than at the first connect.
//
// Presented as a full-screen cover by ContentView whenever no account
// number is stored. Deliberately payment-silent (no prices, no checkout,
// no in-app purchase) — selling happens on the website; see
// docs/BILLING_INTEGRATION.md §9.

import SwiftUI

struct AccountEntryView: View {
    @EnvironmentObject var tunnel: TunnelManager
    @Environment(\.openURL) private var openURL

    @State private var input: String = ""
    @State private var error: String?
    @State private var showPaywall = false
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

                    Text("Enter your account number to get started. No email, no password — your account number is the only key you need.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 28)

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
                                Text("Continue")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
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

                    Button("Lost your account number?") {
                        if let u = URL(string: "https://latticevpn.ai/recover") { openURL(u) }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 10)
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
